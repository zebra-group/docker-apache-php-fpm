# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Dockerfile-based build for a single-container Apache + PHP-FPM base image for PHP CMSes (TYPO3, WordPress, Grav), published to `ghcr.io/zebra-group/php-fpm-apache`. Apache proxies `.php` requests to PHP-FPM over a Unix socket (`/run/php-fpm.sock`); `tini` is PID 1 and `docker/entrypoint.sh` supervises both `php-fpm` and `apache2`.

The deliverable is an image, not an application. **`docs/DEPLOYMENT.md` is the reference document** for build, deploy, all environment variables, tuning and troubleshooting — keep it current with any change to the build or runtime behaviour.

## Commands

Build (context must be repo root, not `docker/`, since the Dockerfile `COPY`s paths relative to repo root):

```sh
docker build -t php-fpm-apache:local -f docker/Dockerfile --build-arg PHP_VERSION=8.4 .
```

Test:

```sh
test/smoke-test.sh php-fpm-apache:local
```

`test/smoke-test.sh` is the test suite. There is no unit-test framework because there is no application code — the tests are behavioural, run against a live container. **Every assertion in it corresponds to a defect this image actually had.** Any behavioural change needs a matching assertion; CI runs the suite against a freshly built image and blocks the push if it fails.

Lint before committing (CI does the same):

```sh
shellcheck docker/entrypoint.sh docker/healthcheck.sh test/smoke-test.sh .github/scripts/apt-index-fingerprint.sh
```

## CI / Release

Four workflows, each answering a different question — see `docs/DEPLOYMENT.md` §3a for the full reasoning.

`.github/workflows/build.yml` runs daily (cron), on manual dispatch, and on push/PR touching `docker/`, `test/`, `.github/scripts/` or the workflow. Pipeline: `lint` (shellcheck + hadolint) → `build` as 4 versions × 2 architectures on **native runners** (`ubuntu-latest` / `ubuntu-24.04-arm`, no QEMU), each building, smoke-testing, Trivy-scanning and pushing by digest → `merge` assembling one multi-arch manifest per tag. A `notify-failure` job opens an issue when a scheduled run fails.

Tags are created **only** in the merge job, so a tag can never reference a half-built set of architectures; the merge job then asserts both architectures are present in what it published. Native runners also mean arm64 is finally smoke-tested — under QEMU it could only be built, since a multi-platform image cannot be loaded into the local daemon. arm64 runners are free because this repo is public; if it ever goes private they become a paid feature and unavailable labels cause jobs to **queue rather than fail**.

`security-scan.yml` scans the *published* registry tags daily and files an issue on fixable HIGH/CRITICAL findings. `pin-drift.yml` checks the PECL pins against upstream weekly. `dependabot.yml` covers action versions.

- `matrix.php_version` is the single source of truth for which tags get built. PHP 8.0/8.1 were dropped as EOL; adding a version means adding it there **and** in the version loop in `security-scan.yml`.
- Tags per build: rolling `:<version>`, immutable `:<version>-<date>` and `:<version>-<sha>`, plus `:latest` for whichever version `LATEST_PHP` names.
- Buildx cache is scoped per PHP version (`scope=php-8.4`). Do not collapse this to a shared key — the matrix jobs then overwrite each other's cache.

**A daily rebuild does not by itself pick up OS security updates.** BuildKit keys the install layer on instruction text plus parent digest, so with a warm cache the `apt-get` step never runs and the build is a no-op. Four things depend on this understanding, and none should be removed as redundant: `pull: true` (re-resolves the base tag so a moved digest busts the cache), the `APT_INDEX_FINGERPRINT` build arg (a hash of the Debian package indices from `.github/scripts/apt-index-fingerprint.sh`, declared but never read in the Dockerfile — it busts the install layer exactly when Debian publishes an update; both build steps must get the same value or the push build diverges from the tested image), the Sunday `no-cache` run (backstop, rebuilds from nothing), and the separate scan of published images (catches CVEs disclosed after build time). `--ignore-unfixed` on the scans is also load-bearing: PHP 8.4 currently has 126 HIGH/CRITICAL findings of which 0 are fixable, so an unfiltered alert would be permanent noise.

## Architecture notes

Configuration is environment-variable driven end to end. **Apache expands `${VAR}` from the process environment natively; PHP-FPM and `php.ini` cannot expand environment variables at all** — that asymmetry is why the entrypoint generates override files instead of templating everything or nothing.

- **`docker/Dockerfile`**: single-stage `FROM php:${PHP_VERSION}-fpm`. Installs `-dev` headers, compiles the extensions, then slims by marking every package auto, re-marking the runtime set, and resolving which shared libraries the built extensions actually link against via `ldd`. Resolved at build time on purpose: library package names differ across Debian releases (`libicu72` on bookworm vs `libicu76` on trixie) and the matrix spans both. The build toolchain is stripped, so downstream images must reinstall `$PHPIZE_DEPS` to add extensions. PECL versions are pinned as build args — an unpinned `pecl install` lets an upstream release break the nightly build.
- **`docker/apache2.conf`**: replaces the entire default `apache2.conf` (not a snippet). Long-lived `Cache-Control` is scoped to static asset extensions via `<FilesMatch>`; PHP responses default to `private, no-cache` using `Header setifempty` so the application stays in control. **Never add a bare `Header set Cache-Control` in server context** — that applies to every response including authenticated backend pages, which is the defect this file was fixing. brotli and deflate are registered in mutually exclusive `<If>`/`<Else>` branches; registering both for the same content types chains them into an undecodable `Content-Encoding: br, gzip`.
- **`docker/www.conf`**: PHP-FPM pool `[www]`, static settings only. `clear_env = no` so environment variables (e.g. DB credentials passed via `docker run -e`) reach PHP. `security.limit_extensions = .php` is the actual defence against executing non-PHP files. All `pm.*` and timeout values come from the generated `zz-runtime.conf`.
- **`docker/php.ini`**: loaded as `zzz-custom.ini`. Static defaults only; runtime-tunable values live in the generated `zzz-runtime.ini`, which sorts after it. `opcache.validate_timestamps` defaults to `0`, so code changes need a restart — settable per environment. `opcache.save_comments = 1` must stay: TYPO3 Extbase and Doctrine read doc comments at runtime.
- **`docker/entrypoint.sh`**: derives config from ENV, waits for the FPM socket before starting Apache, and supervises both processes so the container exits when either dies. Maintains the timeout chain `max_execution_time < request_terminate_timeout < ProxyTimeout`. Refuses to enable `mod_remoteip` unless a trusted proxy range is set, since trusting `X-Forwarded-For` from anywhere lets clients forge their own IP. Runs on every container start — keep it cheap.
- **`docker/healthcheck.sh`**: probes `/fpm-ping` *through Apache*, so one check covers Apache, the socket and FPM. Checking Apache alone would report healthy while every PHP request 503s.

Extension points for downstream images: `/etc/apache2/conf.d/*.conf` and `conf-enabled/*.conf` are included last and win over everything the image ships. `runtime.d/` is generated by the entrypoint — do not write to it.

When editing `apache2.conf`, `www.conf`, or `php.ini`, remember they fully replace upstream defaults rather than layering on top — check what the base `php:*-fpm` and Debian Apache packages normally ship before removing/changing a directive, since there's no fallback config underneath.
