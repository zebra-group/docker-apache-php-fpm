# syntax=docker/dockerfile:1.7
#
# Apache + PHP-FPM base image for TYPO3, WordPress and Grav.
#
# Apache handles static files and proxies *.php to PHP-FPM over a Unix socket.
# Every tunable is an environment variable — see docs/DEPLOYMENT.md. The image
# ships production defaults; nothing needs to be rebuilt to re-tune it.

ARG PHP_VERSION=8.4

FROM php:${PHP_VERSION}-fpm

# Pinned so the daily rebuild is reproducible. An unpinned `pecl install` means
# a new upstream release can break or silently change the image overnight.
ARG IMAGICK_VERSION=3.8.1
ARG APCU_VERSION=5.1.28
ARG REDIS_VERSION=6.3.0
# 3.2.17RC1 rather than the 3.2.16 release: 3.2.16 does not compile on PHP 8.5,
# which removed ext/standard/php_smart_string.h. The RC builds on every version
# in the matrix (8.2–8.5) and is the only version that does. Move to 3.2.17 once
# it is released as stable.
ARG IGBINARY_VERSION=3.2.17RC1

# ImageMagick's Debian policy blocks the PDF/PS coders (historical Ghostscript
# RCEs). CMSes need PDF *reads* for thumbnails, so we re-enable reading by
# default. Set to false if the app never renders PDF previews.
ARG IMAGEMAGICK_ALLOW_PDF=true

# No org.opencontainers.image.licenses label: the repository does not declare a
# license, so there is nothing accurate to put here. Add one once LICENSE exists.
LABEL org.opencontainers.image.source="https://github.com/zebra-group/docker-apache-php-fpm" \
      org.opencontainers.image.title="php-fpm-apache" \
      org.opencontainers.image.description="Apache + PHP-FPM base image for TYPO3, WordPress and Grav"

# Must exist *before* locale-gen runs. Previously this was copied afterwards,
# so the intended locale list was never generated and the image depended on the
# 231 MB locales-all package instead.
COPY docker/locale.gen /etc/locale.gen

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
<<'INSTALL'
set -eux
export DEBIAN_FRONTEND=noninteractive

# Let BuildKit's cache mounts hold the archives instead of the image layer.
rm -f /etc/apt/apt.conf.d/docker-clean
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Remembered so the slimming step below does not purge anything the base image
# had marked as manually installed. Read into an array so the package list stays
# properly quoted when it is restored.
mapfile -t savedAptMark < <(apt-mark showmanual)

runtimePackages=(
    apache2
    apache2-utils
    ca-certificates
    curl
    ghostscript
    imagemagick
    locales
    tini
    unzip
)

# -dev packages needed only to compile the extensions; removed further down.
buildPackages=(
    libavif-dev
    libfreetype6-dev
    libicu-dev
    libjpeg62-turbo-dev
    libldap2-dev
    libmagickwand-dev
    libpng-dev
    libpq-dev
    libsasl2-dev
    libwebp-dev
    libxml2-dev
    libxslt1-dev
    libzip-dev
    zlib1g-dev
)

apt-get update
# Packages already present in the base image (e.g. perl) are never touched by
# the install below, since that only adds the packages named above — an OS CVE
# fixed upstream would otherwise survive every rebuild, cached or not, until
# the base image itself gets rebuilt. `upgrade` (not `dist-upgrade`) never
# removes or adds packages, so it cannot fight the slimming step further down.
apt-get upgrade -y
apt-get install -y --no-install-recommends "${runtimePackages[@]}" "${buildPackages[@]}"

# GD with webp + avif: TYPO3 13 and WordPress both emit WebP derivatives, which
# the previous build could not produce (libwebp-dev was missing entirely).
docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif
docker-php-ext-configure ldap --with-libdir="lib/$(dpkg-architecture --query DEB_HOST_MULTIARCH)"

# pdo_mysql is NOT in the base image and is required by Doctrine DBAL (TYPO3)
# and by most Symfony/Laravel packages. mysqli alone is not enough.
#
# opcache is deliberately absent from this list: every php:*-fpm base image
# already ships it enabled, so installing it only recompiled what was there. On
# PHP 8.5 it is compiled in statically and produces no shared module at all,
# which made `docker-php-ext-install opcache` fail outright
# ("cp: cannot stat 'modules/*'"). It is verified below instead.
docker-php-ext-install -j"$(nproc)" \
    bcmath \
    exif \
    gd \
    intl \
    ldap \
    mysqli \
    pcntl \
    pdo_mysql \
    pdo_pgsql \
    soap \
    sockets \
    xsl \
    zip

# igbinary first: redis links against it for its serializer.
pecl install \
    "igbinary-${IGBINARY_VERSION}" \
    "apcu-${APCU_VERSION}" \
    "imagick-${IMAGICK_VERSION}"
pecl install --configureoptions 'enable-redis-igbinary="yes"' "redis-${REDIS_VERSION}"
docker-php-ext-enable apcu igbinary imagick redis

# --- Slimming -------------------------------------------------------------
# Mark everything auto, then re-mark only the runtime packages plus whatever
# the compiled extensions actually link against (resolved via ldd, so this
# stays correct across Debian releases where library sonames differ).
# This drops the -dev headers *and* the build toolchain: ~450 MB.
apt-mark auto '.*' > /dev/null
[ "${#savedAptMark[@]}" -eq 0 ] || apt-mark manual "${savedAptMark[@]}" > /dev/null
apt-mark manual "${runtimePackages[@]}" > /dev/null

# The base image marks the build toolchain as manually installed so downstream
# images can compile extensions, and restoring savedAptMark above brings that
# back. This image bakes in every extension it needs, so the toolchain is
# released for removal here — gcc, g++, cpp, binutils and the libc headers come
# to roughly 200 MB. Downstream images that need to add an extension reinstall
# $PHPIZE_DEPS themselves; see docs/DEPLOYMENT.md §8.
# shellcheck disable=SC2086  # intentional word splitting: one arg per package
apt-mark auto ${PHPIZE_DEPS} > /dev/null

# PHPIZE_DEPS names "libc-dev", which is a *virtual* package — apt-mark cannot
# act on it, so the real header packages would survive. Named explicitly here.
apt-mark auto libc6-dev libc-dev-bin linux-libc-dev libcrypt-dev > /dev/null 2>&1 || true

# Resolved one library at a time on purpose: dpkg-query exits non-zero for any
# path it does not own, which would abort the whole pipeline under `pipefail`.
#
# Each library is looked up under several paths because of Debian's usr-merge:
# ldd reports "/lib/<triplet>/libfoo.so", while dpkg's file list records the
# real location "/usr/lib/<triplet>/libfoo.so". Querying only what ldd printed
# finds nothing at all, which would silently purge every runtime library.
declare -A keepPackages=()
while read -r lib; do
    [ -n "${lib}" ] || continue
    pkg=""
    for candidate in "${lib}" "/usr${lib}" "$(realpath -m "${lib}" 2>/dev/null || true)"; do
        [ -n "${candidate}" ] || continue
        pkg="$(dpkg-query --search "${candidate}" 2>/dev/null | cut -d: -f1 || true)"
        [ -n "${pkg}" ] && break
    done
    [ -n "${pkg}" ] && keepPackages["${pkg}"]=1
done < <(ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
         | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 0) print so }' \
         | sort -u)

echo "keeping runtime libraries: ${!keepPackages[*]}"

# Fail loudly rather than purge everything the extensions link against. An empty
# result means the path resolution above broke, not that there are no dependencies.
if [ "${#keepPackages[@]}" -lt 5 ]; then
    echo "FATAL: resolved only ${#keepPackages[@]} runtime library packages;" \
         "expected many. Refusing to purge."
    exit 1
fi
apt-mark manual "${!keepPackages[@]}" > /dev/null

apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

# Sanity check: the purge above must not have taken anything we depend on.
# Written to a file first because `grep -q` closes the pipe early, which makes
# `php -m` die of SIGPIPE and trips `pipefail`.
php -m > /tmp/loaded-modules.txt
for required in pdo_mysql pdo_pgsql mysqli gd intl imagick redis apcu igbinary \
                bcmath pcntl sockets xsl ldap soap zip exif; do
    grep -qx "${required}" /tmp/loaded-modules.txt \
        || { echo "FATAL: extension ${required} missing after slimming"; exit 1; }
done

# OPcache comes from the base image rather than being installed here, so verify
# it is actually present. It reports under its display name, not "opcache".
grep -qx 'Zend OPcache' /tmp/loaded-modules.txt \
    || { echo "FATAL: OPcache is not loaded"; exit 1; }
command -v convert > /dev/null
command -v curl > /dev/null

locale-gen
rm -rf /tmp/pear /tmp/loaded-modules.txt /var/log/apache2/* /usr/src/php.tar.xz*
INSTALL

RUN <<'CONFIGURE'
set -eux

# Apache modules. brotli/remoteip/http2 were all available but unused; fcgid was
# installed and loaded while the config actually proxies via proxy_fcgi.
a2enmod \
    brotli \
    deflate \
    expires \
    filter \
    headers \
    http2 \
    proxy_fcgi \
    remoteip \
    rewrite \
    setenvif \
    status

# other-vhosts-access-log writes an unrotated file inside the container that
# `docker logs` never sees; serve-cgi-bin exposes /cgi-bin/ for no reason.
#
# security.conf is disabled because conf-enabled/ is included at the END of our
# apache2.conf (so downstream config can override us), which means its
# `ServerTokens OS` would win over the `ServerTokens Prod` we set. We define all
# of its directives ourselves instead.
a2disconf other-vhosts-access-log serve-cgi-bin security

# Debian's mods-available/deflate.conf registers DEFLATE for common text types
# in global scope. Our apache2.conf includes mods-enabled/*.conf near the top,
# so that registration would happen before — and independently of — the
# mutually exclusive brotli/deflate branches we define. The effect is that gzip
# always wins and brotli never applies (mod_brotli declines once a
# Content-Encoding is already set). Keep the module loaded, drop its config.
rm -f /etc/apache2/mods-enabled/deflate.conf

# Our apache2.conf and www.conf fully replace these rather than layering on top.
rm -rf /etc/apache2/sites-enabled /etc/apache2/sites-available
rm -f /usr/local/etc/php-fpm.d/zz-docker.conf \
      /usr/local/etc/php-fpm.d/www.conf \
      /usr/local/etc/php-fpm.d/www.conf.default \
      /usr/local/etc/php-fpm.conf.default

# runtime.d is generated by the entrypoint from environment variables.
# conf.d / conf-enabled stay free for downstream images and are included last
# so they win over everything we ship.
mkdir -p /etc/apache2/runtime.d /etc/apache2/conf.d /var/run/apache2 /var/www/html
chown www-data:www-data /var/www/html

# Body for the /healthz alias. Lives outside DocumentRoot so that bind-mounting
# application code over /var/www/html cannot hide it.
mkdir -p /usr/local/share/apache2-healthz
echo 'ok' > /usr/local/share/apache2-healthz/ok.txt
CONFIGURE

# Allow ImageMagick to *read* PDF/PS so CMS thumbnail generation works.
RUN <<'POLICY'
set -eux
if [ "${IMAGEMAGICK_ALLOW_PDF}" != "true" ]; then
    echo "ImageMagick PDF policy left at Debian default (reads blocked)."
    exit 0
fi
shopt -s nullglob
found=0
for policy in /etc/ImageMagick-*/policy.xml; do
    # Drop only the read restriction on the document coders; write stays denied.
    sed -i -E '/<policy[^>]*domain="coder"[^>]*rights="none"[^>]*pattern="(PDF|PS|PS2|PS3|EPS|XPS)"/d' "${policy}"
    found=1
done
[ "${found}" = "1" ] || echo "No ImageMagick policy.xml found — nothing to relax."
POLICY

COPY docker/php.ini        /usr/local/etc/php/conf.d/zzz-custom.ini
COPY docker/www.conf       /usr/local/etc/php-fpm.d/www.conf
COPY docker/apache2.conf   /etc/apache2/apache2.conf
COPY docker/entrypoint.sh  /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh

# Verified build rather than piping an unsigned installer through PHP.
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

RUN <<'FINALIZE'
set -eux
chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

# Validate the shipped pool config at build time, so a syntax error fails the
# build instead of every container start.
#
# www.conf deliberately carries no `pm` setting — the process manager and all
# worker counts come from zz-runtime.conf, which the entrypoint writes from the
# environment and which does not exist yet. A throwaway pool file supplies the
# missing keys just for this check; it is removed immediately afterwards so it
# cannot mask a missing runtime config later.
cat > /usr/local/etc/php-fpm.d/zz-buildcheck.conf <<'CHECK'
[www]
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
CHECK
php-fpm --test
rm /usr/local/etc/php-fpm.d/zz-buildcheck.conf

composer --version --no-interaction > /dev/null
FINALIZE

WORKDIR /var/www/html

EXPOSE 80

# The previous image had no healthcheck: when PHP-FPM died the container stayed
# "running" and served 503s indefinitely. This probes Apache *and* FPM.
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
