# Apache + PHP-FPM Docker Image

A single-container Apache + PHP-FPM base image for PHP CMSes — TYPO3, WordPress,
Grav and similar. Apache serves static files and proxies `*.php` to PHP-FPM over
a Unix socket.

Published to `ghcr.io/zebra-group/php-fpm-apache`.

```sh
docker run -d -p 8080:80 -v "$(pwd)/html:/var/www/html" \
    ghcr.io/zebra-group/php-fpm-apache:8.4
```

**Tuning, environment variables and troubleshooting: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).**

---

## Tags

| Tag | |
|---|---|
| `8.2` `8.3` `8.4` `8.5` | Rolling, rebuilt nightly |
| `8.4-20260803` | Immutable date snapshot — **pin this in production** |
| `8.4-a1b2c3d` | Immutable commit snapshot |
| `latest` | Currently 8.4 |

PHP 8.0 and 8.1 are no longer built (end of life, no upstream security patches).
The existing tags remain in the registry but are frozen.

## What's included

**Extensions** beyond the `php:*-fpm` base: `apcu`, `bcmath`, `exif`, `gd`
(FreeType/JPEG/PNG/WebP/AVIF), `igbinary`, `imagick`, `intl`, `ldap`, `mysqli`,
`opcache`, `pcntl`, `pdo_mysql`, `pdo_pgsql`, `redis`, `soap`, `sockets`, `xsl`,
`zip`.

**Also**: Composer 2, the ImageMagick CLI plus Ghostscript (TYPO3 drives
`convert`/`identify` directly for image processing), and the locales
`de_DE`, `en_US`, `en_GB`, `fr_FR`, `ru_RU`, `ar_AE`, `vi_VN`, `fa_IR`.

**Apache modules**: `proxy_fcgi`, `rewrite`, `headers`, `expires`, `deflate`,
`brotli`, `remoteip`, `http2`, `setenvif`, `filter`, `status`.

## Operating it

| Endpoint | |
|---|---|
| `/healthz` | Liveness, served from disk without touching PHP |
| `/fpm-ping` | `pong` via Apache → PHP-FPM (proves the whole chain); container-local |
| `/fpm-status` | PHP-FPM pool metrics; container-local |
| `/server-status` | Apache MPM state; container-local |

Logs go to stdout/stderr only — `docker logs` is the single source of truth. The
container exits if either Apache or PHP-FPM dies, and ships a `HEALTHCHECK`.

## Quick tuning

Sane defaults ship in the image; `PHP_FPM_MAX_CHILDREN` is derived from the
container's memory limit if not set. For a site around 3.5M pageviews/month:

```yaml
services:
  web:
    image: ghcr.io/zebra-group/php-fpm-apache:8.4-20260803
    environment:
      PHP_FPM_MAX_CHILDREN: 24
      PHP_FPM_PM: static
      PHP_OPCACHE_MEMORY: 384
      APACHE_MAX_REQUEST_WORKERS: 256
      PHP_TIMEZONE: Europe/Berlin
      PHP_SESSION_HANDLER: redis
      PHP_SESSION_PATH: tcp://redis:6379
      # Required together behind a load balancer, or all client IPs are the proxy's:
      APACHE_REMOTE_IP_HEADER: X-Forwarded-For
      APACHE_REMOTE_IP_TRUSTED_PROXY: 10.0.0.0/8
    deploy:
      resources:
        limits:
          memory: 3G
```

Two defaults worth knowing about:

- **`PHP_OPCACHE_VALIDATE_TIMESTAMPS=0`** — code changes are *not* picked up
  without a container restart. Set to `1` for bind-mounted development code.
- **Sessions are container-local files in `/tmp`** — lost on restart and not
  shared between replicas. Use Redis when scaling out.

The full reference is in [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## Extending

`conf.d/` is included last, so it overrides anything the image ships:

```dockerfile
FROM ghcr.io/zebra-group/php-fpm-apache:8.4-20260803

COPY docker/typo3.conf /etc/apache2/conf.d/typo3.conf
COPY --chown=www-data:www-data . /var/www/html
```

The build toolchain is stripped from the image to keep it small — see
[`docs/DEPLOYMENT.md` §8](docs/DEPLOYMENT.md) for how to add a PHP extension
downstream.

## Development

```
docker/
  Dockerfile        single-stage build, slimmed via apt-mark + ldd resolution
  apache2.conf      replaces Debian's apache2.conf entirely
  www.conf          PHP-FPM pool (static settings only)
  php.ini           loaded as zzz-custom.ini
  locale.gen        locales generated into the image
  entrypoint.sh     ENV -> config, startup ordering, process supervision
  healthcheck.sh    probes PHP-FPM through Apache
test/
  smoke-test.sh     behavioural test suite
docs/
  DEPLOYMENT.md     build, deploy, tuning, troubleshooting
```

Build (context must be the repository root — the Dockerfile `COPY`s
`docker/…` paths):

```sh
docker build -t php-fpm-apache:local -f docker/Dockerfile --build-arg PHP_VERSION=8.4 .
test/smoke-test.sh php-fpm-apache:local
```

`apache2.conf`, `www.conf` and `php.ini` **fully replace** their upstream
counterparts — there is no distro default underneath them.

Every assertion in `test/smoke-test.sh` maps to a defect this image actually had.
Add one alongside any behavioural change; CI runs the suite before pushing.

`.github/workflows/build.yml` lints, then builds each PHP version for
`linux/amd64` and `linux/arm64` on **native runners** — smoke-testing and
Trivy-scanning both — and assembles the multi-arch manifest in a separate merge
job, with SBOM and provenance. Tags are only created after both architectures
succeed. The `matrix.php_version` list is the single source of truth for which
tags get built.

Keeping the image current is deliberately split across four mechanisms, because a
nightly rebuild alone is a no-op whenever the layer cache is warm:

| | |
|---|---|
| `build.yml` daily | new `php:*-fpm` base image (`pull: true` busts the cache) |
| `build.yml` Sundays, `no-cache` | Debian updates the base image did not force |
| `security-scan.yml` daily | CVEs disclosed *after* an image was built |
| `pin-drift.yml` + Dependabot | stale PECL pins and action versions |

Findings and scheduled-build failures are raised as GitHub issues. Full reasoning,
including the one failure mode to watch (GitHub disables cron after 60 days of
repository inactivity), is in [`docs/DEPLOYMENT.md` §3a](docs/DEPLOYMENT.md).

## License

[MIT](LICENSE) — matching `docker-library/php`, the upstream project the
`php:*-fpm` base image is built from.
