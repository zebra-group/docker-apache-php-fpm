# Deployment & Build

How the `php-fpm-apache` base image is built, published and tuned. Written to be
usable without prior DevOps background — if something here is unclear, that is a
bug in this document.

---

## 1. What this is

A single-container **Apache + PHP-FPM** base image for PHP CMSes (TYPO3,
WordPress, Grav). It is not an application: it is the runtime other images are
built `FROM`, or that application code is mounted into.

```
                       ┌─────────────────────────── container ──────────────────────────┐
   request :80  ──────▶│  Apache (mpm_event)                                            │
                       │    ├─ static files, compression, caching  ─────▶ response       │
                       │    └─ *.php ──▶ Unix socket /run/php-fpm.sock ──▶ PHP-FPM pool  │
                       │                                                                │
                       │  tini (PID 1) ──▶ entrypoint.sh ──┬─▶ php-fpm  (supervised)     │
                       │                                   └─▶ apache2   (supervised)   │
                       └────────────────────────────────────────────────────────────────┘
```

Key properties:

- **Apache and PHP-FPM talk over a Unix socket**, not TCP — no network stack
  overhead, and PHP is unreachable from outside the container.
- **`tini` is PID 1**, so zombie processes get reaped and signals are forwarded.
- **The entrypoint supervises both processes.** If either dies, the container
  exits so the orchestrator restarts it.
- **Everything is tuned through environment variables.** No rebuild is needed to
  change worker counts, timeouts, caching or logging.

### Published tags

Images go to `ghcr.io/zebra-group/php-fpm-apache`:

| Tag | Meaning |
|---|---|
| `8.2` `8.3` `8.4` `8.5` | Rolling — rebuilt daily, moves |
| `8.4-20260803` | Immutable date snapshot — use this to pin or roll back |
| `8.4-a1b2c3d` | Immutable commit snapshot |
| `latest` | Alias for the version in `LATEST_PHP` (currently 8.4) |

**Pin an immutable tag in production.** The rolling tags move every night; if a
daily rebuild ever ships a regression, a date tag is what you roll back to.

PHP 8.0 and 8.1 are **no longer built** — both are end-of-life and their base
images receive no security patches. The old tags remain in the registry but are
frozen.

---

## 2. Building locally

The build context must be the **repository root**, not `docker/`, because the
Dockerfile `COPY`s paths like `docker/php.ini`:

```sh
docker build -t php-fpm-apache:local -f docker/Dockerfile --build-arg PHP_VERSION=8.4 .
```

Run it:

```sh
docker run -d --name web -p 8080:80 -v "$(pwd)/html:/var/www/html" php-fpm-apache:local
curl http://localhost:8080/healthz     # -> ok
```

### Build arguments

| Argument | Default | Purpose |
|---|---|---|
| `PHP_VERSION` | `8.4` | Base image tag (`php:<version>-fpm`) |
| `IMAGICK_VERSION` | `3.8.1` | Pinned so a new PECL release cannot break the nightly build |
| `APCU_VERSION` | `5.1.28` | " |
| `REDIS_VERSION` | `6.3.0` | " |
| `IGBINARY_VERSION` | `3.2.17RC1` | A release candidate on purpose — see below |

`IGBINARY_VERSION` is the one pin that is not a stable release. igbinary 3.2.16
does not compile on PHP 8.5, which removed `ext/standard/php_smart_string.h`;
3.2.17RC1 builds across the whole 8.2–8.5 matrix and is currently the only
version that does. Move it to 3.2.17 once that is released as stable.
| `IMAGEMAGICK_ALLOW_PDF` | `true` | Allows ImageMagick to *read* PDF/PS so CMS thumbnail generation works. Debian blocks this by default because of historical Ghostscript RCEs. Set `false` if the application never renders PDF previews. |

### Why the image is the size it is

Measured for PHP 8.4/arm64, before and after the slimming work:

| Metric | Before | After |
|---|---|---|
| Filesystem contents | 1182 MB | **445 MB** |
| Installed packages (dpkg) | 1148 MB | 428 MB |
| Compressed pull size | 355 MB | **228 MB** |

And that is with more extensions than before (`pdo_mysql`, `pdo_pgsql`, `bcmath`,
`pcntl`, `sockets`, `xsl`, `ldap`, `redis`, `apcu`, `igbinary`, plus WebP/AVIF
support in GD).

Where it came from: dropping `locales-all` (231 MB, made redundant once the
locale list was actually applied), the `-dev` headers, and the build toolchain.
The build installs what it needs to compile, then `apt-mark auto '.*'` marks
everything as automatically installed, re-marks the runtime packages manually,
and uses `ldd` to discover which shared libraries the compiled extensions
actually link against. Only those survive `apt-get purge --auto-remove`.

Two details in that resolution are easy to get wrong:

- Library packages are resolved at build time rather than hardcoded, because the
  names differ between Debian releases (`libicu72` on bookworm vs `libicu76` on
  trixie) and the PHP matrix spans both.
- `ldd` reports paths like `/lib/<triplet>/libfoo.so`, but Debian's usr-merge
  means dpkg records them under `/usr/lib/<triplet>/`. Querying only what `ldd`
  printed resolves *nothing*, which would purge every runtime library. Several
  path variants are tried per library, and the build aborts if the resolution
  yields implausibly few packages.

**The remaining floor is the base image.** `php:8.4-fpm` is itself ~505 MB of
filesystem, and its own layer contains the build toolchain. Purging the toolchain
removes it from the running filesystem but not from the inherited layer, so
`docker images` still reports around 1 GB of layer sum for a 445 MB filesystem.
Going below that means building PHP on top of `debian:*-slim` instead of using
the official image — worth roughly another 200 MB uncompressed, at the cost of
maintaining the PHP build itself across four versions and two architectures.
That trade was not taken.

### Tests

```sh
test/smoke-test.sh php-fpm-apache:local
```

There is no unit-test framework — the deliverable is an image, so the tests are
behavioural. Every assertion in `test/smoke-test.sh` corresponds to a defect this
image actually had, and exists so it cannot return unnoticed. CI runs the suite
against a freshly built image **before** anything is pushed.

---

## 3. CI/CD

`.github/workflows/build.yml`.

**Triggers:** daily at 00:00 UTC, on manual dispatch, and on push/PR touching
`docker/`, `test/` or the workflow.

**Pipeline:**

```
lint ──▶ build   (4 versions × 2 architectures = 8 jobs, each on a NATIVE runner)
         │        amd64 → ubuntu-latest      arm64 → ubuntu-24.04-arm
         │
         ├─ 1. build for this architecture, load into the local daemon
         ├─ 2. run test/smoke-test.sh        ← blocks publication if it fails
         ├─ 3. Trivy scan (fails on fixable CRITICAL)
         └─ 4. push an untagged, digest-addressed image
                     │
                     ▼
         merge   (one job per version)
         ├─ combine the two digests into one multi-arch manifest per tag
         └─ verify the published manifest really contains both architectures
```

Two design points worth keeping:

- **Native runners, no QEMU.** Emulating arm64 to compile this many extensions
  dominated the pipeline, and it meant arm64 was only ever *built* — never
  tested, because a multi-platform image cannot be loaded into the local Docker
  daemon. One job per architecture removes the emulation and gets the smoke
  tests running on both. GitHub-hosted arm64 runners are free for public
  repositories; on a private repository they need a Team or Enterprise plan, and
  an unavailable runner label causes jobs to **queue indefinitely rather than
  fail**. The fallback is to restore `docker/setup-qemu-action` and build both
  platforms in one job.
- **Tags are created only in the merge job.** Each build job pushes by digest
  with no tag attached, so a tag can never point at a half-built set of
  architectures. The merge job then asserts that the manifest it just published
  contains both `linux/amd64` and `linux/arm64` — a tag that silently lost an
  architecture is worse than a failed build, because consumers only discover it
  at pull time.

`lint` runs `shellcheck` on the shell scripts and `hadolint` on the Dockerfile.

**Secrets:** none to configure. The workflow uses the automatically provided
`GITHUB_TOKEN` with `packages: write`, declared explicitly in the `permissions`
block.

**Caching:** GitHub Actions cache (`type=gha`), scoped per PHP version *and*
architecture (`scope=php-8.4-arm64`). The scope matters — with a shared key the
matrix jobs overwrite each other's cache and every build starts cold.

**Supply chain:** pushes include SBOM (`sbom: true`) and full provenance
attestation (`provenance: mode=max`). Each run records the base image digest it
built from in the run summary, so an incident can be traced to a specific
upstream image.

---

## 3a. How security updates actually reach the image

A daily rebuild is necessary but **not sufficient**, for a reason that is easy to
miss: BuildKit keys the install layer on the instruction text plus the parent
layer digest. With a warm cache the entire `apt-get` step is a cache hit and
never executes. A nightly build against an unchanged base image produces a
byte-identical image and picks up nothing.

Four mechanisms cover the gap, each answering a different question:

| Workflow | Cadence | Answers |
|---|---|---|
| `build.yml` | daily 00:00 UTC | Is there a newer `php:*-fpm`? (new PHP patch release, or Debian updates the official image baked in) |
| `build.yml` with `no-cache` | Sundays | Are there Debian updates for the packages *we* install, that the base image did not force? |
| `security-scan.yml` | daily 06:00 UTC | Is what we already published vulnerable *today*? |
| `pin-drift.yml` + Dependabot | weekly | Are the PECL pins and action versions stale? |

**Daily (`build.yml`).** `pull: true` forces re-resolution of the
`php:<version>-fpm` tag on every run, so a moved upstream digest invalidates the
cache and the whole image is rebuilt. This is the main path: the official PHP
images are rebuilt when Debian ships security updates, so most patches arrive
here.

**Weekly cache bypass.** On Sundays the build runs with `no-cache: true`, so the
install layer re-executes regardless of whether the base image moved. Within
that layer, `apt-get upgrade -y` runs before the package install — without it,
re-running the layer only reinstalls the packages this Dockerfile names
explicitly, and a package the *base image* already had (e.g. `perl`) survives
untouched even across a from-scratch rebuild. This is the backstop for updates
the base image does not force. Only the test build bypasses the cache; the
subsequent push build reuses what it just produced, so even a from-scratch run
compiles each architecture once. Force one at any time:

```sh
gh workflow run build.yml -f no_cache=true
```

**Daily scan of published images (`security-scan.yml`).** The build-time scan can
only catch what was known when the image was built; most CVEs are disclosed
afterwards. This scans the actual registry tags and opens (or updates) a GitHub
issue when a **fixable** HIGH/CRITICAL appears, closing it again once clean.

`--ignore-unfixed` is deliberate and load-bearing. Measured against PHP 8.4:
**126** HIGH/CRITICAL findings exist in total, **0** of them have a fix available
upstream. Without the filter the alert would fire permanently on things nobody
can act on, and would be ignored within a week.

**Pins.** `pin-drift.yml` compares the PECL versions in the Dockerfile against
PECL's current stable releases weekly and raises an issue on divergence. It does
not open a PR, because bumping a pin needs a verified build across the whole PHP
matrix. Dependabot covers the GitHub Actions versions; it cannot cover the base
image (a build argument it cannot resolve, and one that is meant to float) or
PECL (no such ecosystem).

**Failure is visible.** A `notify-failure` job opens an issue when a scheduled
run fails. Note what a failed build means: nothing is broken for consumers, since
the previous tags stay published — but security updates have silently stopped
arriving. That is exactly the failure mode worth an alert.

### The one thing to watch

> **GitHub disables scheduled workflows after 60 days without repository
> activity.** For a base image repository that is working correctly — no commits
> needed, just nightly rebuilds — this is the single most likely way the whole
> mechanism stops, and it stops quietly.

GitHub emails the repository owners when it happens. To recover, re-enable in the
Actions tab, or:

```sh
gh api -X PUT "repos/zebra-group/docker-apache-php-fpm/actions/workflows/build.yml/enable"
```

If the repository is expected to sit idle for long stretches, drive the rebuild
from something outside it instead — an org-level scheduled workflow calling
`workflow_dispatch`, or any external scheduler hitting the API. Verify the
mechanism is alive by checking that new date tags are actually appearing in the
registry, not by assuming the cron still runs.

### A note on build cost

Both architectures build on native runners, so there is no QEMU penalty. This
repository is public, which makes GitHub-hosted arm64 runners free.

If it is ever made private, arm64 runners become a paid feature: the label stops
resolving and those jobs queue instead of failing, which looks like a hang rather
than an error. Either move to a plan that includes them, or fall back to
`docker/setup-qemu-action` with both platforms in a single job — slower, and
arm64 then goes untested again.

---

## 4. Configuration reference

All configuration is environment variables. The entrypoint applies them by
writing override files at container start:

| Generated file | Contains |
|---|---|
| `/usr/local/etc/php-fpm.d/zz-runtime.conf` | `pm.*`, timeouts, status paths |
| `/usr/local/etc/php/conf.d/zzz-runtime.ini` | memory, timezone, OPcache, sessions |
| `/etc/apache2/runtime.d/remoteip.conf` | `mod_remoteip`, only when a trusted proxy is set |

Apache reads its own `${VARIABLE}` references straight from the environment.
PHP-FPM and `php.ini` cannot expand environment variables at all, which is why
those are generated.

### PHP

| Variable | Default | Notes |
|---|---|---|
| `PHP_MEMORY_LIMIT` | `512M` | Per request. TYPO3 backend wants ≥256M; 512M is headroom for image processing. |
| `PHP_MAX_EXECUTION_TIME` | `120` | Drives the whole timeout chain (below). |
| `PHP_MAX_INPUT_TIME` | `120` | |
| `PHP_TIMEZONE` | `UTC` | Set to e.g. `Europe/Berlin`. |
| `PHP_OPCACHE_MEMORY` | `256` | MB, shared across all workers. |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `0` | **`0` means code changes are not picked up without a restart.** Set `1` for bind-mounted development code. |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `2` | Only applies when the above is `1`. |
| `PHP_OPCACHE_FILE_CACHE` | `/tmp/opcache` | On-disk opcode cache; cheaper cold starts. |
| `PHP_OPCACHE_JIT` | `off` | `tracing` to enable. Off by default on purpose — see §5. |
| `PHP_OPCACHE_JIT_BUFFER_SIZE` | `128M` | |
| `PHP_OPCACHE_PRELOAD` | *(empty)* | Path to a preload script. Big win for TYPO3 v11+/Symfony. |
| `PHP_SESSION_HANDLER` | `files` | Set `redis` when running more than one replica. |
| `PHP_SESSION_PATH` | `/tmp` | e.g. `tcp://redis:6379`. |
| `PHP_EXTRA_INI` | *(empty)* | Extra raw ini lines; `\n` separated. |

### PHP-FPM

| Variable | Default | Notes |
|---|---|---|
| `PHP_FPM_MAX_CHILDREN` | *derived* | Max concurrent PHP requests. See §5. |
| `PHP_FPM_PM` | `dynamic` | `static` for steady high traffic, `ondemand` for many idle sites. |
| `PHP_FPM_AVG_WORKER_MEMORY_MB` | `96` | Used only for the automatic derivation. |
| `RESERVED_MEMORY_MB` | `192` | Held back for Apache, the FPM master and the OS. |
| `PHP_FPM_MAX_REQUESTS` | `500` | Recycle a worker after N requests (guards against leaks). |
| `PHP_FPM_REQUEST_TERMINATE_TIMEOUT` | *derived* | Hard kill; catches requests blocked outside PHP. |
| `PHP_FPM_SLOWLOG_TIMEOUT` | `5s` | Backtrace of any request slower than this, to stderr. |
| `PHP_FPM_ACCESS_LOG` | `off` | `on` adds FPM-side timings. Apache already logs requests. |

### Apache

| Variable | Default | Notes |
|---|---|---|
| `APACHE_SERVER_NAME` | `localhost` | |
| `APACHE_PORT` | `80` | |
| `APACHE_MAX_REQUEST_WORKERS` | `128` | Worker threads. Rounded to a multiple of `APACHE_THREADS_PER_CHILD`. |
| `APACHE_THREADS_PER_CHILD` | `32` | `ServerLimit` is derived from these two. |
| `APACHE_TIMEOUT` | `60` | |
| `APACHE_PROXY_TIMEOUT` | *derived* | `PHP_MAX_EXECUTION_TIME + 20`. |
| `APACHE_KEEPALIVE` | `On` | |
| `APACHE_KEEPALIVE_TIMEOUT` | `3` | Low on purpose: behind a proxy, connections are reused by the proxy. |
| `APACHE_MAX_KEEPALIVE_REQUESTS` | `100` | |
| `APACHE_MAX_CONNECTIONS_PER_CHILD` | `0` | `0` = never recycle. PHP is out-of-process, so recycling only costs restarts. |
| `APACHE_ALLOW_OVERRIDE` | `All` | `None` removes a `stat()` per directory level per request — only once `.htaccess` rules are baked into `conf.d/`. |
| `APACHE_ASSET_CACHE_MAX_AGE` | `2592000` | Seconds, static assets (30 days). |
| `APACHE_ASSET_CACHE_TIME` | `30 days` | `mod_expires` equivalent of the above; keep the two in sync. |
| `APACHE_BROTLI` | `On` | |
| `APACHE_BROTLI_QUALITY` | `5` | 1–11. Above ~6 costs more CPU than it saves bandwidth for dynamic output. |
| `APACHE_DEFLATE_LEVEL` | `6` | |
| `APACHE_LOG_LEVEL` | `warn` | |
| `APACHE_LOG_FORMAT` | `combined` | `combined_time` adds request duration in µs. |
| `APACHE_ENABLE_SENDFILE` | `On` | Set `Off` on NFS/fuse volumes, where the kernel can serve stale content. |
| `APACHE_ENABLE_MMAP` | `On` | Same. |
| `APACHE_REMOTE_IP_HEADER` | *(empty)* | e.g. `X-Forwarded-For`. |
| `APACHE_REMOTE_IP_TRUSTED_PROXY` | *(empty)* | **Required** for the above to take effect. |

### Behind a reverse proxy

Without `mod_remoteip`, Apache and PHP see only the proxy's IP: access logs are
useless, `$_SERVER['REMOTE_ADDR']` is wrong, and anything IP-based (rate limits,
the TYPO3 backend IP lock, WordPress login throttling) silently misbehaves.

```yaml
environment:
  APACHE_REMOTE_IP_HEADER: X-Forwarded-For
  APACHE_REMOTE_IP_TRUSTED_PROXY: 10.0.0.0/8 172.16.0.0/12
```

Both are required. Setting only the header would let **any client forge its own
IP address** by sending `X-Forwarded-For`, so the entrypoint refuses to enable
`mod_remoteip` and logs a warning instead.

Set the trusted range to your proxy's actual network. Note that `mod_remoteip`
**rejects `0.0.0.0/0`** outright (`Error parsing IP ... network mask is
invalid`), so there is no catch-all shortcut — and an unparseable value stops the
container at startup rather than quietly running without the trust
configuration you asked for. Multiple ranges are space separated.

---

## 5. Tuning for real traffic

### The concurrency model

Apache has more worker threads than PHP-FPM has children, on purpose. Apache
terminates connections and serves static files; PHP-FPM does the expensive work.
Requests beyond FPM's capacity queue on the Unix socket (`listen.backlog = 1024`)
instead of being refused.

**`PHP_FPM_MAX_CHILDREN` is the real concurrency limit for PHP.** If it is unset,
the entrypoint derives it from the container's memory limit:

```
children = (memory_limit − PHP_OPCACHE_MEMORY − RESERVED_MEMORY_MB) / PHP_FPM_AVG_WORKER_MEMORY_MB
```

The computed value is logged at startup. Set it explicitly in production so
capacity does not change when you resize the container.

### Sizing for ~3.5 million pageviews/month

3.5M/month is ≈1.4 requests/second averaged out, but average is not what you
size for. German business-hours traffic typically concentrates ~15 % of the day
into the peak hour, which puts the realistic peak at **20–30 dynamic requests per
second**, plus bursts from crawlers and campaigns.

Required PHP concurrency is `peak_rps × average_response_time`:

| Response time | at 25 req/s | Comment |
|---|---|---|
| 50 ms (cache hit) | ~1.5 workers | TYPO3 page cache / WP object cache hit |
| 200 ms | ~5 workers | typical mixed |
| 800 ms (cache miss) | ~20 workers | uncached rendering |

Starting point:

```yaml
# 3.5M pageviews/month, single container, ~3 GB RAM
environment:
  PHP_FPM_MAX_CHILDREN: 24
  PHP_FPM_PM: static           # no fork latency under load
  PHP_MEMORY_LIMIT: 512M
  PHP_OPCACHE_MEMORY: 384      # large TYPO3 installs benefit
  APACHE_MAX_REQUEST_WORKERS: 256
  APACHE_THREADS_PER_CHILD: 32
  PHP_SESSION_HANDLER: redis
  PHP_SESSION_PATH: tcp://redis:6379
  PHP_TIMEZONE: Europe/Berlin
deploy:
  resources:
    limits:
      memory: 3G
```

Rough sizing table:

| Traffic | RAM | `PHP_FPM_MAX_CHILDREN` | `APACHE_MAX_REQUEST_WORKERS` | `PHP_FPM_PM` |
|---|---|---|---|---|
| < 500k/month | 1 GB | 6 | 64 | `dynamic` |
| ~3.5M/month | 3 GB | 24 | 256 | `static` |
| > 10M/month | 4 GB × N replicas | 32 | 256 | `static` |

**These are starting points, not answers.** Validate against `/fpm-status`
(§6) — `max children reached` above zero means you are under-provisioned;
`max active processes` far below `max_children` means you are over-provisioned
and wasting memory that OPcache could use.

### What actually moves the needle

Ordered by impact for a CMS at this traffic level:

1. **The application's own page cache.** A TYPO3 or WordPress cache hit is 10–20×
   cheaper than a miss. Everything below is secondary to this.
2. **Redis for object cache and sessions.** `redis`, `apcu` and `igbinary` are
   compiled in. File-based sessions in `/tmp` are lost on restart and *not shared
   between replicas* — a second replica logs everyone out.
3. **OPcache sizing.** `PHP_OPCACHE_MEMORY` must exceed the total compiled size
   of the codebase, or the cache thrashes. Check `opcache_get_status()`.
4. **A CDN or caching proxy in front.** Static assets already carry a 30-day
   `Cache-Control`; let something else serve them.
5. **`APACHE_ALLOW_OVERRIDE=None`**, once rewrite rules are baked into `conf.d/`.
6. **OPcache preloading** (`PHP_OPCACHE_PRELOAD`) for TYPO3 v11+.

`PHP_OPCACHE_JIT` is deliberately off. For template- and database-bound CMS
workloads JIT usually changes little and occasionally regresses. Measure before
enabling it.

### Scaling out

Beyond one container, these must be shared rather than container-local:

- **Sessions** → `PHP_SESSION_HANDLER=redis`
- **The application cache** → Redis
- **Uploaded files** (`fileadmin/`, `wp-content/uploads/`) → a shared volume or
  object storage

---

## 6. Operating the container

### Health

Two endpoints, both restricted to inside the container except `/healthz`:

| Endpoint | Purpose |
|---|---|
| `/healthz` | Static file, no PHP. For load balancer probes that should be cheap. |
| `/fpm-ping` | Returns `pong` through Apache → PHP-FPM. Proves the whole chain. |
| `/fpm-status` | Pool metrics. `Require local`. |
| `/server-status` | Apache MPM state. `Require local`. |

The image's `HEALTHCHECK` uses `/fpm-ping`, so Docker reports `unhealthy` when
PHP-FPM stops answering — the previous image had no healthcheck and would report
`running` while serving 503s to every request.

```sh
docker exec web curl -s localhost/fpm-status
docker inspect -f '{{.State.Health.Status}}' web
```

### Logs

Everything goes to stdout/stderr; `docker logs` is the only place to look. No log
files are written inside the container. Health probes are excluded from the
access log so they do not drown out real traffic.

```sh
docker logs -f web
APACHE_LOG_FORMAT=combined_time    # adds request duration in µs
PHP_FPM_SLOWLOG_TIMEOUT=2s         # backtrace for anything slower than 2s
```

### Finding what is slow

1. `APACHE_LOG_FORMAT=combined_time` → which URLs are slow.
2. `PHP_FPM_SLOWLOG_TIMEOUT=2s` → a PHP backtrace showing *where* they hang.
3. `/fpm-status?full` → per-worker state and the current request.

---

## 7. Troubleshooting

**Code changes have no effect.**
`PHP_OPCACHE_VALIDATE_TIMESTAMPS=0` by default: PHP never re-checks the
filesystem. Intended for production, wrong for development. Set it to `1`, or
restart the container.

**503 Service Unavailable on every PHP request.**
PHP-FPM is not answering. With this image the container should have exited — check
`docker logs` for `php-fpm exited unexpectedly`. If it is running, check
`docker exec web ls -l /run/php-fpm.sock`.

**503 only on long-running requests.**
`APACHE_PROXY_TIMEOUT` is below the actual runtime. It defaults to
`PHP_MAX_EXECUTION_TIME + 20`, so raise `PHP_MAX_EXECUTION_TIME` rather than
setting the timeout directly, and keep the chain intact:
`max_execution_time < request_terminate_timeout < ProxyTimeout`.

**Container is killed / OOM.**
`PHP_FPM_MAX_CHILDREN × PHP_MEMORY_LIMIT` exceeds the container limit. `memory_limit`
is a per-request ceiling, not a reservation, so the sizing uses
`PHP_FPM_AVG_WORKER_MEMORY_MB` (a realistic average) instead. If workers really
do approach the limit, lower `PHP_FPM_MAX_CHILDREN`.

**Requests queue and latency climbs, CPU is idle.**
FPM is saturated. Check `max children reached` in `/fpm-status`; raise
`PHP_FPM_MAX_CHILDREN` if memory allows, otherwise reduce response time.

**All client IPs look like the load balancer.**
See "Behind a reverse proxy" in §4. Both variables are required.

**Logged-in pages are served to the wrong user, or stale.**
Should not happen with this image — long-lived caching is scoped to static
asset extensions and PHP responses default to `private, no-cache`. If you see
it, check whether something in `conf.d/` sets a bare `Header set Cache-Control`
in server context: that applies to *every* response, which is exactly the defect
this configuration was fixing.

**PDF thumbnails fail in TYPO3.**
Requires `IMAGEMAGICK_ALLOW_PDF=true` at build time (the default) and
`ghostscript`, which is installed. Also confirm TYPO3's `[GFX][processor_path]`
points at `/usr/bin/`.

**Sessions are lost, or users are logged out at random.**
File-based sessions in `/tmp`, plus more than one replica. Switch to Redis.

**`docker stop` takes 30 seconds.**
Signals are not reaching the processes. The entrypoint traps `TERM` and sends
Apache `SIGWINCH` (graceful stop) and FPM `SIGQUIT`; shutdown should take about a
second on an idle container. If it does not, check that `tini` is still PID 1.

---

## 8. Extending the image

Two extension points are included at the end of `apache2.conf`, both after
everything the image ships, so they win:

```
/etc/apache2/conf.d/*.conf         free for downstream images and bind mounts
/etc/apache2/conf-enabled/*.conf   distro + a2enconf
```

Drop vhost or rewrite snippets there rather than replacing `apache2.conf`.

```dockerfile
FROM ghcr.io/zebra-group/php-fpm-apache:8.4-20260803

COPY docker/typo3.conf /etc/apache2/conf.d/typo3.conf
COPY --chown=www-data:www-data . /var/www/html
```

Note that the build toolchain (`gcc`, `make`, `autoconf`) is **removed** from the
image to keep it small. To add a PHP extension downstream, install it back
temporarily:

```dockerfile
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    pecl install mongodb; \
    docker-php-ext-enable mongodb; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/*
```

`apache2.conf`, `www.conf` and `php.ini` **fully replace** their upstream
counterparts rather than layering on top — there is no distro default
underneath. Check what the base `php:*-fpm` image and Debian's Apache packages
normally ship before removing a directive.
