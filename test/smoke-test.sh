#!/usr/bin/env bash
#
# Smoke tests for the php-fpm-apache image.
#
# Every check here corresponds to a defect that was actually present in this
# image at some point. They exist so those defects cannot come back silently.
#
# Usage:
#   test/smoke-test.sh [IMAGE]
#
# IMAGE defaults to php-fpm-apache:test. Requires docker and curl.
#
set -uo pipefail

IMAGE="${1:-php-fpm-apache:test}"
CONTAINER="smoketest-$$"
PORT="${SMOKE_TEST_PORT:-18099}"
WORKDIR="$(mktemp -d)"
BASE="http://127.0.0.1:${PORT}"

PASS=0
FAIL=0
FAILED_NAMES=()

# --- harness -----------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# assert_contains NAME HAYSTACK NEEDLE
assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *)      bad "$1" "expected to contain '$3', got: $(printf '%s' "$2" | head -c 300)" ;;
    esac
}

# assert_not_contains NAME HAYSTACK NEEDLE
assert_not_contains() {
    case "$2" in
        *"$3"*) bad "$1" "should NOT contain '$3', got: $(printf '%s' "$2" | head -c 300)" ;;
        *)      ok "$1" ;;
    esac
}

# Invoked indirectly via trap, which shellcheck cannot see. Both codes are listed
# because which one fires depends on the shellcheck version: SC2317 in 0.9.x,
# SC2329 in 0.11.x.
# shellcheck disable=SC2329,SC2317
cleanup() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

in_container() { docker exec "${CONTAINER}" "$@"; }

# --- fixtures ----------------------------------------------------------------

mkdir -p "${WORKDIR}/html"
cat > "${WORKDIR}/html/index.php" <<'PHP'
<?php
echo "hello from php";
PHP

cat > "${WORKDIR}/html/info.php" <<'PHP'
<?php
echo json_encode([
    'extensions'   => get_loaded_extensions(),
    'expose_php'   => ini_get('expose_php'),
    'memory_limit' => ini_get('memory_limit'),
    'max_exec'     => ini_get('max_execution_time'),
    'timezone'     => ini_get('date.timezone'),
    'validate_ts'  => ini_get('opcache.validate_timestamps'),
    'save_comments'=> ini_get('opcache.save_comments'),
    'locales'      => setlocale(LC_ALL, 'de_DE.UTF-8'),
    'gd'           => function_exists('gd_info') ? gd_info() : null,
]);
PHP

cat > "${WORKDIR}/html/slow.php" <<'PHP'
<?php
// Sleeps past Apache's old 60s Timeout to prove the proxy no longer gives up
// before PHP's max_execution_time.
$seconds = isset($_GET['s']) ? (int) $_GET['s'] : 3;
sleep($seconds);
echo "slept {$seconds}";
PHP

# Large, highly compressible body so compression is unambiguous.
{ printf '<html><body>'; for _ in $(seq 1 400); do
    printf 'compressible filler text that repeats many times over. ';
  done; printf '</body></html>'; } > "${WORKDIR}/html/big.html"

printf 'body { color: red; }\n%.0s' $(seq 1 200) > "${WORKDIR}/html/style.css"

# A file that must never be executed or served.
echo 'SECRET=must-not-be-served' > "${WORKDIR}/html/.env"

bold "==> Image: ${IMAGE}"

# =============================================================================
bold "==> Static image checks"
# =============================================================================

# Measured inside the container rather than via `docker image inspect .Size`,
# because that value depends on the storage driver: the containerd image store
# and overlay2 report different numbers for the same image. Filesystem usage is
# comparable everywhere and is what actually has to fit on the host.
fs_mb="$(docker run --rm --entrypoint sh "${IMAGE}" -c "du -sm / 2>/dev/null | tail -1 | cut -f1")"
inspect_mb=$(( $(docker image inspect "${IMAGE}" --format '{{.Size}}') / 1024 / 1024 ))
printf '  filesystem: %s MB   (docker-reported: %s MB)\n' "${fs_mb}" "${inspect_mb}"

# Was 1182 MB before slimming. Guard against silently regrowing.
if [ "${fs_mb}" -lt 700 ]; then
    ok "image filesystem under 700 MB budget (${fs_mb} MB)"
else
    bad "image filesystem under 700 MB budget" "filesystem is ${fs_mb} MB"
fi

# The build toolchain is deliberately stripped; if it reappears, ~200 MB came
# back with it.
toolchain="$(docker run --rm --entrypoint sh "${IMAGE}" -c \
    'command -v gcc >/dev/null 2>&1 && echo present || echo absent')"
assert_eq "build toolchain stripped" "absent" "${toolchain}"

hc="$(docker image inspect "${IMAGE}" --format '{{if .Config.Healthcheck}}yes{{else}}no{{end}}')"
assert_eq "HEALTHCHECK is defined" "yes" "${hc}"

# apt lists and dev headers must not be shipped.
apt_lists="$(docker run --rm --entrypoint sh "${IMAGE}" -c \
    'du -sm /var/lib/apt/lists 2>/dev/null | cut -f1 || echo 0')"
if [ "${apt_lists:-0}" -le 2 ]; then
    ok "apt lists not shipped in image (${apt_lists} MB)"
else
    bad "apt lists not shipped in image" "${apt_lists} MB left in /var/lib/apt/lists"
fi

# dpkg keeps a record of purged packages, and `dpkg-query -W <pkg>` still exits 0
# for them. The Status field is what distinguishes installed from removed.
pkg_state() {
    docker run --rm --entrypoint sh "${IMAGE}" -c \
        "dpkg-query -Wf '\${Status}' '$1' 2>/dev/null | grep -q 'ok installed' \
         && echo present || echo absent"
}

devpkgs="$(docker run --rm --entrypoint sh "${IMAGE}" -c \
    "dpkg-query -Wf '\${Package} \${Status}\n' 2>/dev/null \
     | awk '\$4 == \"installed\" && \$1 ~ /-dev\$/' | wc -l | tr -d ' '")"
assert_eq "no -dev packages remain" "0" "${devpkgs}"

# apt-get install only adds the packages this image names explicitly; without
# a separate upgrade step, an already-installed base-image package with a
# known fixed CVE (e.g. perl) would survive every rebuild untouched.
upgradable="$(docker run --rm --entrypoint sh "${IMAGE}" -c \
    'apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -vc "^Listing"')"
assert_eq "no upgradable OS packages remain after build" "0" "${upgradable}"

assert_eq "locales-all (231 MB) removed" "absent" "$(pkg_state locales-all)"
assert_eq "unused mod_fcgid removed" "absent" "$(pkg_state libapache2-mod-fcgid)"
assert_eq "obsolete libmcrypt-dev removed" "absent" "$(pkg_state libmcrypt-dev)"

# Locales must actually be generated (the list used to be copied after
# locale-gen ran, so it had no effect), and the names must be valid.
gen_locales="$(docker run --rm --entrypoint sh "${IMAGE}" -c 'locale -a 2>/dev/null')"
for loc in de_DE.utf8 en_US.utf8 fr_FR.utf8 ru_RU.utf8 fa_IR.utf8 ar_AE.utf8 vi_VN.utf8; do
    assert_contains "locale ${loc} generated" "${gen_locales}" "${loc}"
done

# =============================================================================
bold "==> Container startup"
# =============================================================================

docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
    -p "${PORT}:80" \
    -v "${WORKDIR}/html:/var/www/html" \
    -e PHP_TIMEZONE=Europe/Berlin \
    -e PHP_MAX_EXECUTION_TIME=90 \
    "${IMAGE}" >/dev/null

# Wait for readiness rather than sleeping a fixed amount.
ready=0
for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "${BASE}/index.php" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.5
done
if [ "${ready}" = "1" ]; then
    ok "container serves PHP after startup"
else
    bad "container serves PHP after startup" "$(docker logs "${CONTAINER}" 2>&1 | tail -20)"
    red "aborting: container never became ready"
    exit 1
fi

startup_logs="$(docker logs "${CONTAINER}" 2>&1)"
assert_contains "entrypoint logs derived sizing" "${startup_logs}" "php-fpm:"
assert_not_contains "no undefined Apache config variables" "${startup_logs}" "is not defined"
assert_not_contains "no Apache config warnings at startup" "${startup_logs}" "AH00117"
assert_not_contains "MaxRequestWorkers is a multiple of ThreadsPerChild" \
    "${startup_logs}" "MaxRequestWorkers of"

# =============================================================================
bold "==> Caching headers (the 1-year-cache-on-PHP defect)"
# =============================================================================

php_headers="$(curl -sSI "${BASE}/index.php")"
assert_not_contains "PHP response is not cached for a year" \
    "${php_headers}" "max-age=31536000"
assert_contains "PHP response is marked private/no-cache" \
    "$(printf '%s' "${php_headers}" | tr '[:upper:]' '[:lower:]')" "private"
assert_not_contains "PHP response is not publicly cacheable" \
    "$(printf '%s' "${php_headers}" | tr '[:upper:]' '[:lower:]' | grep -i '^cache-control' || echo '')" "public"

css_headers="$(curl -sSI "${BASE}/style.css")"
assert_contains "static asset is publicly cacheable" \
    "$(printf '%s' "${css_headers}" | tr '[:upper:]' '[:lower:]')" "public"
assert_contains "static asset has a long max-age" \
    "${css_headers}" "max-age=2592000"
# immutable strands clients on stale query-string-versioned assets.
assert_not_contains "static asset is not marked immutable" "${css_headers}" "immutable"

# An application setting its own policy must win.
cat > "${WORKDIR}/html/cacheable.php" <<'PHP'
<?php
header('Cache-Control: public, max-age=600');
echo "app-controlled caching";
PHP
app_cc="$(curl -sSI "${BASE}/cacheable.php" | tr '[:upper:]' '[:lower:]' | grep -i '^cache-control' || echo '')"
assert_contains "application Cache-Control is not overridden" "${app_cc}" "max-age=600"

# =============================================================================
bold "==> Information disclosure"
# =============================================================================

assert_not_contains "X-Powered-By header removed" "${php_headers}" "X-Powered-By"
server_hdr="$(printf '%s' "${php_headers}" | grep -i '^server:' || echo '')"
assert_not_contains "Apache version not advertised" "${server_hdr}" "Apache/2"
assert_not_contains "Debian not advertised" "${server_hdr}" "Debian"

env_status="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/.env")"
assert_eq ".env is not served" "403" "${env_status}"

# =============================================================================
bold "==> PHP configuration and extensions
"
# =============================================================================

info_json="$(curl -fsS "${BASE}/info.php")"

for ext in pdo_mysql mysqli pdo_pgsql gd intl zip soap bcmath exif \
           pcntl sockets xsl ldap imagick redis apcu igbinary; do
    assert_contains "extension ${ext} present" "${info_json}" "\"${ext}\""
done
# get_loaded_extensions() reports OPcache under its display name, not "opcache".
assert_contains "extension OPcache present" "${info_json}" '"Zend OPcache"'

assert_contains "expose_php is Off" "${info_json}" '"expose_php":""'
assert_contains "opcache.save_comments stays enabled (TYPO3/Doctrine)" \
    "${info_json}" '"save_comments":"1"'
assert_contains "PHP_TIMEZONE env is applied" "${info_json}" '"timezone":"Europe\/Berlin"'
assert_contains "PHP_MAX_EXECUTION_TIME env is applied" "${info_json}" '"max_exec":"90"'
assert_contains "de_DE locale usable from PHP" "${info_json}" 'de_DE.UTF-8'

# GD must be able to write the formats a modern CMS emits.
assert_contains "GD has WebP support" "${info_json}" '"WebP Support":true'
assert_contains "GD has AVIF support" "${info_json}" '"AVIF Support":true'
assert_contains "GD has FreeType support" "${info_json}" '"FreeType Support":true'

# Deprecated/removed directives must not produce startup noise.
ini_warnings="$(in_container php -i 2>&1 >/dev/null || true)"
assert_not_contains "no E_STRICT deprecation from php.ini" "${ini_warnings}" "E_STRICT"
assert_not_contains "no unknown-directive warnings" "${ini_warnings}" "track_errors"

# ImageMagick CLI is what TYPO3 drives for image processing.
convert_ok="$(in_container sh -c 'command -v convert >/dev/null && echo yes || echo no')"
assert_eq "ImageMagick CLI available for TYPO3" "yes" "${convert_ok}"

# =============================================================================
bold "==> Compression (must never double-encode)"
# =============================================================================

enc_br="$(curl -sS -H 'Accept-Encoding: gzip, deflate, br' -o /dev/null \
          -D - "${BASE}/big.html" | tr '[:upper:]' '[:lower:]' \
          | grep -i '^content-encoding' | tr -d '\r' | sed 's/.*: *//')"
assert_eq "brotli chosen for br-capable client" "br" "${enc_br}"

enc_gzip="$(curl -sS -H 'Accept-Encoding: gzip' -o /dev/null \
            -D - "${BASE}/big.html" | tr '[:upper:]' '[:lower:]' \
            | grep -i '^content-encoding' | tr -d '\r' | sed 's/.*: *//')"
assert_eq "gzip chosen for gzip-only client" "gzip" "${enc_gzip}"

raw_size="$(curl -sS -o /dev/null -w '%{size_download}' "${BASE}/big.html")"
if [ "${raw_size}" -gt 1000 ]; then
    ok "compressible fixture is large enough to test (${raw_size} bytes)"
else
    bad "compressible fixture is large enough to test" "only ${raw_size} bytes"
fi

# =============================================================================
bold "==> Timeout chain: max_execution_time < request_terminate < ProxyTimeout"
# =============================================================================

# 65s exceeds the old hardcoded Apache Timeout of 60 but stays under the
# configured max_execution_time of 90, so it must succeed rather than 503.
slow_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 100 "${BASE}/slow.php?s=65")"
assert_eq "request longer than 60s no longer 503s" "200" "${slow_code}"

fpm_conf="$(in_container cat /usr/local/etc/php-fpm.d/zz-runtime.conf)"
assert_contains "request_terminate_timeout derived from max_execution_time" \
    "${fpm_conf}" "request_terminate_timeout = 100"
assert_contains "slowlog timeout configured" "${fpm_conf}" "request_slowlog_timeout"
assert_contains "fpm status path configured" "${fpm_conf}" "pm.status_path = /fpm-status"

# =============================================================================
bold "==> Monitoring endpoints"
# =============================================================================

ping="$(in_container curl -fsS "http://127.0.0.1/fpm-ping")"
assert_eq "fpm-ping answers from inside" "pong" "${ping}"

status="$(in_container curl -fsS "http://127.0.0.1/fpm-status")"
assert_contains "fpm-status exposes pool metrics" "${status}" "idle processes"

healthz="$(curl -fsS "${BASE}/healthz")"
assert_eq "healthz served without PHP" "ok" "${healthz}"

# Must not be reachable from outside the container.
ext_status="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/fpm-status")"
assert_eq "fpm-status blocked from outside" "403" "${ext_status}"

# The container's own healthcheck must pass.
health_state=""
for _ in $(seq 1 40); do
    health_state="$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "")"
    [ "${health_state}" = "healthy" ] && break
    sleep 1
done
assert_eq "docker healthcheck reports healthy" "healthy" "${health_state}"

# =============================================================================
bold "==> Logging"
# =============================================================================

curl -fsS "${BASE}/index.php" >/dev/null
sleep 1
logs="$(docker logs "${CONTAINER}" 2>&1)"

# Apache and FPM both logging the same request produced duplicate lines.
req_lines="$(printf '%s\n' "${logs}" | grep -c 'GET /index.php' || true)"
if [ "${req_lines}" -ge 1 ]; then
    ok "requests are logged to docker logs (${req_lines} line(s) for last request)"
else
    bad "requests are logged to docker logs" "no access log line found"
fi

# No unrotated log files growing inside the container.
logfiles="$(in_container sh -c 'find /var/log/apache2 -type f -size +0 2>/dev/null | wc -l')"
assert_eq "no log files written inside the container" "0" "${logfiles}"

# Health probes must not spam the access log.
in_container curl -fsS "http://127.0.0.1/fpm-ping" >/dev/null
sleep 1
ping_logged="$(docker logs "${CONTAINER}" 2>&1 | grep -c 'fpm-ping' || true)"
assert_eq "health probes excluded from access log" "0" "${ping_logged}"

# =============================================================================
bold "==> Failure handling"
# =============================================================================

# Killing PHP-FPM used to leave the container "running" while every PHP request
# returned 503, with nothing to signal the orchestrator.
in_container pkill -f 'php-fpm: master' >/dev/null 2>&1 || true

died=0
for _ in $(seq 1 30); do
    state="$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo gone)"
    if [ "${state}" != "running" ]; then died=1; break; fi
    sleep 1
done
if [ "${died}" = "1" ]; then
    ok "container exits when PHP-FPM dies"
else
    bad "container exits when PHP-FPM dies" \
        "container still running; PHP status: $(curl -s -o /dev/null -w '%{http_code}' "${BASE}/index.php")"
fi

# =============================================================================
bold "==> Graceful shutdown"
# =============================================================================

docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" -p "${PORT}:80" \
    -v "${WORKDIR}/html:/var/www/html" "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "${BASE}/index.php" >/dev/null 2>&1 && break
    sleep 0.5
done

stop_start="$(date +%s)"
docker stop -t 30 "${CONTAINER}" >/dev/null
stop_elapsed=$(( $(date +%s) - stop_start ))
# A container that ignores SIGTERM is killed at the 30s timeout instead.
if [ "${stop_elapsed}" -lt 20 ]; then
    ok "responds to SIGTERM promptly (${stop_elapsed}s)"
else
    bad "responds to SIGTERM promptly" "took ${stop_elapsed}s — signals likely not forwarded"
fi

shutdown_logs="$(docker logs "${CONTAINER}" 2>&1 | tail -5)"
assert_contains "shutdown is logged by the entrypoint" "${shutdown_logs}" "shutting down"

# =============================================================================
bold "==> ENV-driven tuning"
# =============================================================================

docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" -p "${PORT}:80" \
    -v "${WORKDIR}/html:/var/www/html" \
    -e PHP_FPM_MAX_CHILDREN=7 \
    -e PHP_FPM_PM=static \
    -e APACHE_MAX_REQUEST_WORKERS=64 \
    -e APACHE_THREADS_PER_CHILD=16 \
    -e PHP_MEMORY_LIMIT=256M \
    -e APACHE_ASSET_CACHE_MAX_AGE=99 \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "${BASE}/index.php" >/dev/null 2>&1 && break
    sleep 0.5
done

tuned_fpm="$(in_container cat /usr/local/etc/php-fpm.d/zz-runtime.conf)"
assert_contains "PHP_FPM_MAX_CHILDREN honoured" "${tuned_fpm}" "pm.max_children = 7"
assert_contains "PHP_FPM_PM=static honoured" "${tuned_fpm}" "pm = static"
assert_not_contains "static pool omits dynamic-only keys" "${tuned_fpm}" "pm.min_spare_servers"

tuned_info="$(curl -fsS "${BASE}/info.php")"
assert_contains "PHP_MEMORY_LIMIT honoured" "${tuned_info}" '"memory_limit":"256M"'

tuned_css="$(curl -sSI "${BASE}/style.css")"
assert_contains "APACHE_ASSET_CACHE_MAX_AGE honoured" "${tuned_css}" "max-age=99"

# Derived ServerLimit must satisfy MaxRequestWorkers = ServerLimit * ThreadsPerChild.
tuned_logs="$(docker logs "${CONTAINER}" 2>&1)"
assert_contains "Apache sizing derived from ENV" "${tuned_logs}" "4 x 16"
assert_not_contains "no MPM sizing warning" "${tuned_logs}" "MaxRequestWorkers of"

# mod_remoteip must refuse to trust forwarded headers without a trusted proxy.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" -p "${PORT}:80" \
    -v "${WORKDIR}/html:/var/www/html" \
    -e APACHE_REMOTE_IP_HEADER=X-Forwarded-For \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "${BASE}/index.php" >/dev/null 2>&1 && break
    sleep 0.5
done
spoof_logs="$(docker logs "${CONTAINER}" 2>&1)"
assert_contains "mod_remoteip refuses to trust XFF without a trusted proxy" \
    "${spoof_logs}" "refusing to enable mod_remoteip"

remoteip_conf="$(in_container sh -c 'cat /etc/apache2/runtime.d/remoteip.conf 2>/dev/null || true')"
assert_not_contains "no RemoteIPHeader without trusted proxy" "${remoteip_conf}" "RemoteIPHeader"

# With a trusted proxy it must take effect and log the forwarded address.
#
# The RFC1918 ranges cover the Docker bridge gateway the request actually arrives
# from, on both Docker Desktop (192.168.65.1) and Linux runners (172.17.0.1).
# Note that mod_remoteip rejects 0.0.0.0/0 outright ("network mask is invalid"),
# so a catch-all cannot be used here.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" -p "${PORT}:80" \
    -v "${WORKDIR}/html:/var/www/html" \
    -e APACHE_REMOTE_IP_HEADER=X-Forwarded-For \
    -e APACHE_REMOTE_IP_TRUSTED_PROXY='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16' \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "${BASE}/index.php" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -fsS -H 'X-Forwarded-For: 203.0.113.42' "${BASE}/index.php" >/dev/null
sleep 1
assert_contains "real client IP appears in access log via mod_remoteip" \
    "$(docker logs "${CONTAINER}" 2>&1)" "203.0.113.42"

# A malformed proxy list must stop the container rather than silently run
# without the trust configuration the operator asked for.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" -p "${PORT}:80" \
    -e APACHE_REMOTE_IP_HEADER=X-Forwarded-For \
    -e APACHE_REMOTE_IP_TRUSTED_PROXY='not-a-cidr/99' \
    "${IMAGE}" >/dev/null
bad_cfg_died=0
for _ in $(seq 1 20); do
    state="$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo gone)"
    if [ "${state}" != "running" ]; then bad_cfg_died=1; break; fi
    sleep 1
done
if [ "${bad_cfg_died}" = "1" ]; then
    ok "invalid trusted-proxy value fails the container at startup"
else
    bad "invalid trusted-proxy value fails the container at startup" \
        "container kept running with a rejected mod_remoteip config"
fi

# =============================================================================
bold "==> Passthrough commands"
# =============================================================================

php_version="$(docker run --rm "${IMAGE}" php -v 2>&1)"
assert_contains "docker run <image> php -v works" "${php_version}" "PHP"

# Not piped through `head -1`: composer splits its banner across stdout and
# stderr, so with 2>&1 the line order is not deterministic and pinning the first
# line made this assertion flaky rather than meaningful.
composer_version="$(docker run --rm "${IMAGE}" composer --version --no-interaction 2>&1)"
assert_contains "composer is installed and runnable" "${composer_version}" "Composer version"

# =============================================================================
bold "==> Result"
# =============================================================================

printf '\n'
if [ "${FAIL}" -eq 0 ]; then
    green "All ${PASS} checks passed."
    exit 0
fi

red "${FAIL} of $((PASS+FAIL)) checks failed:"
for name in "${FAILED_NAMES[@]}"; do
    printf '  - %s\n' "${name}"
done
exit 1
