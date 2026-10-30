#!/usr/bin/env bash
#
# Container entrypoint.
#
# Three jobs, in order:
#   1. Turn environment variables into config. PHP-FPM and php.ini cannot expand
#      env vars themselves, so the tunables are written out as override files.
#   2. Start PHP-FPM, wait for its socket, then start Apache. Starting Apache
#      first meant the first requests after every container start could 503.
#   3. Supervise both. If either process exits, tear the other down and exit
#      non-zero, so the container dies instead of serving 503s while appearing
#      healthy.
#
set -euo pipefail

log()  { printf '[entrypoint] %s\n' "$*" >&2; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }

# Anything other than "serve" is run verbatim, so `docker run <image> php -v`
# and `... composer install` keep working.
if [ "${1:-serve}" != "serve" ]; then
    exec "$@"
fi

# =============================================================================
# Defaults
# =============================================================================
# Fixed, not tunable: www.conf hardcodes the same path for `listen`.
PHP_FPM_SOCKET=/run/php-fpm.sock

# --- PHP ---------------------------------------------------------------------
: "${PHP_MEMORY_LIMIT:=512M}"
: "${PHP_MAX_EXECUTION_TIME:=120}"
: "${PHP_MAX_INPUT_TIME:=120}"
: "${PHP_TIMEZONE:=UTC}"
: "${PHP_OPCACHE_MEMORY:=256}"
# 0 = never stat the filesystem (production: code only changes with the image).
# Set to 1 for bind-mounted development code, otherwise edits are never picked
# up without restarting the container.
: "${PHP_OPCACHE_VALIDATE_TIMESTAMPS:=0}"
: "${PHP_OPCACHE_REVALIDATE_FREQ:=2}"
: "${PHP_OPCACHE_JIT:=off}"
: "${PHP_OPCACHE_JIT_BUFFER_SIZE:=128M}"
: "${PHP_OPCACHE_PRELOAD:=}"
: "${PHP_OPCACHE_FILE_CACHE:=/tmp/opcache}"
: "${PHP_SESSION_HANDLER:=files}"
: "${PHP_SESSION_PATH:=/tmp}"
: "${PHP_EXTRA_INI:=}"

# --- PHP-FPM -----------------------------------------------------------------
: "${PHP_FPM_PM:=dynamic}"
: "${PHP_FPM_MAX_CHILDREN:=}"          # empty = derive from memory limit
: "${PHP_FPM_AVG_WORKER_MEMORY_MB:=96}"
: "${PHP_FPM_MAX_REQUESTS:=500}"
: "${PHP_FPM_PROCESS_IDLE_TIMEOUT:=10s}"
: "${PHP_FPM_SLOWLOG_TIMEOUT:=5s}"
: "${PHP_FPM_ACCESS_LOG:=off}"
# Reserved for Apache, the FPM master and the OS when deriving worker counts.
: "${RESERVED_MEMORY_MB:=192}"

# --- Apache ------------------------------------------------------------------
: "${APACHE_SERVER_NAME:=localhost}"
: "${APACHE_PORT:=80}"
: "${APACHE_TIMEOUT:=60}"
: "${APACHE_KEEPALIVE:=On}"
: "${APACHE_MAX_KEEPALIVE_REQUESTS:=100}"
: "${APACHE_KEEPALIVE_TIMEOUT:=3}"
: "${APACHE_LOG_LEVEL:=warn}"
: "${APACHE_LOG_FORMAT:=combined}"
: "${APACHE_ENABLE_SENDFILE:=On}"
: "${APACHE_ENABLE_MMAP:=On}"
: "${APACHE_ALLOW_OVERRIDE:=All}"
: "${APACHE_THREADS_PER_CHILD:=32}"
: "${APACHE_MAX_REQUEST_WORKERS:=128}"
: "${APACHE_MAX_CONNECTIONS_PER_CHILD:=0}"
: "${APACHE_ASYNC_REQUEST_WORKER_FACTOR:=2}"
: "${APACHE_BROTLI:=On}"
: "${APACHE_BROTLI_QUALITY:=5}"
: "${APACHE_DEFLATE_LEVEL:=6}"
: "${APACHE_ASSET_CACHE_MAX_AGE:=2592000}"
: "${APACHE_REMOTE_IP_HEADER:=}"
: "${APACHE_REMOTE_IP_TRUSTED_PROXY:=}"

# =============================================================================
# Derive PHP-FPM worker count
#
# The old config hardcoded pm.max_children = 50 next to memory_limit = 512M,
# i.e. up to 25 GB of theoretical demand — far past any realistic container
# limit, so the OOM killer decided concurrency instead of the config.
# =============================================================================
detect_memory_limit_mb() {
    local bytes=""

    if [ -r /sys/fs/cgroup/memory.max ]; then                       # cgroup v2
        bytes="$(cat /sys/fs/cgroup/memory.max)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then    # cgroup v1
        bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    fi

    # "max", empty, or an implausibly large sentinel all mean "no limit set".
    if [ -z "${bytes}" ] || [ "${bytes}" = "max" ] \
       || ! [ "${bytes}" -gt 0 ] 2>/dev/null \
       || [ "${bytes}" -gt 1099511627776 ]; then
        # Without a limit the whole host's RAM is assumed to be ours — wrong as
        # soon as several containers share the host.
        warn "no container memory limit found — sizing PHP-FPM from host RAM." \
             "Set a memory limit or PHP_FPM_MAX_CHILDREN."
        bytes="$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))"
    fi

    echo "$(( bytes / 1024 / 1024 ))"
}

if [ -z "${PHP_FPM_MAX_CHILDREN}" ]; then
    total_mb="$(detect_memory_limit_mb)"
    # OPcache is shared memory: counted once for the pool, not per worker.
    usable_mb=$(( total_mb - PHP_OPCACHE_MEMORY - RESERVED_MEMORY_MB ))
    [ "${usable_mb}" -lt 128 ] && usable_mb=128

    PHP_FPM_MAX_CHILDREN=$(( usable_mb / PHP_FPM_AVG_WORKER_MEMORY_MB ))
    [ "${PHP_FPM_MAX_CHILDREN}" -lt 2 ]   && PHP_FPM_MAX_CHILDREN=2
    [ "${PHP_FPM_MAX_CHILDREN}" -gt 256 ] && PHP_FPM_MAX_CHILDREN=256

    log "memory available: ${total_mb}MB -> pm.max_children=${PHP_FPM_MAX_CHILDREN}" \
        "(opcache ${PHP_OPCACHE_MEMORY}MB, reserved ${RESERVED_MEMORY_MB}MB," \
        "~${PHP_FPM_AVG_WORKER_MEMORY_MB}MB/worker)"

    if [ "${total_mb}" -lt 512 ]; then
        warn "only ${total_mb}MB available — set PHP_FPM_MAX_CHILDREN and" \
             "PHP_MEMORY_LIMIT explicitly for predictable behaviour."
    fi
else
    log "pm.max_children=${PHP_FPM_MAX_CHILDREN} (explicitly configured)"
fi

# start/spare servers scale with the pool. FPM warns when start_servers falls
# outside [min_spare, max_spare], so these are kept consistent by construction.
fpm_min_spare=$(( PHP_FPM_MAX_CHILDREN / 4 ))
[ "${fpm_min_spare}" -lt 1 ] && fpm_min_spare=1
fpm_max_spare=$(( PHP_FPM_MAX_CHILDREN * 3 / 4 ))
[ "${fpm_max_spare}" -lt "${fpm_min_spare}" ] && fpm_max_spare="${fpm_min_spare}"
fpm_start_servers=$(( (fpm_min_spare + fpm_max_spare) / 2 ))
[ "${fpm_start_servers}" -lt 1 ] && fpm_start_servers=1

# =============================================================================
# Derive the timeout chain
#
#   max_execution_time  <  request_terminate_timeout  <  ProxyTimeout
#
# PHP's own limit must fire first so the app gets a catchable error and a
# backtrace; FPM's is the hard backstop for requests blocked outside PHP (a
# hanging database or HTTP call, which max_execution_time does not interrupt);
# Apache must outlast both, or it returns 503 while the worker keeps going.
# =============================================================================
: "${PHP_FPM_REQUEST_TERMINATE_TIMEOUT:=$(( PHP_MAX_EXECUTION_TIME + 10 ))}"
: "${APACHE_PROXY_TIMEOUT:=$(( PHP_MAX_EXECUTION_TIME + 20 ))}"

if [ "${APACHE_PROXY_TIMEOUT}" -le "${PHP_MAX_EXECUTION_TIME}" ]; then
    warn "APACHE_PROXY_TIMEOUT (${APACHE_PROXY_TIMEOUT}s) is not greater than" \
         "PHP_MAX_EXECUTION_TIME (${PHP_MAX_EXECUTION_TIME}s): long requests" \
         "will return 503 while PHP is still working."
fi

# =============================================================================
# Derive Apache MPM sizing
# =============================================================================
# MaxRequestWorkers must be a multiple of ThreadsPerChild or Apache rounds it
# down and logs a warning at every start.
apache_server_limit=$(( (APACHE_MAX_REQUEST_WORKERS + APACHE_THREADS_PER_CHILD - 1)
                        / APACHE_THREADS_PER_CHILD ))
[ "${apache_server_limit}" -lt 1 ] && apache_server_limit=1
APACHE_MAX_REQUEST_WORKERS=$(( apache_server_limit * APACHE_THREADS_PER_CHILD ))

: "${APACHE_START_SERVERS:=$(( apache_server_limit < 2 ? apache_server_limit : 2 ))}"
: "${APACHE_MIN_SPARE_THREADS:=${APACHE_THREADS_PER_CHILD}}"
: "${APACHE_MAX_SPARE_THREADS:=$(( APACHE_THREADS_PER_CHILD * 2 ))}"
[ "${APACHE_MAX_SPARE_THREADS}" -gt "${APACHE_MAX_REQUEST_WORKERS}" ] \
    && APACHE_MAX_SPARE_THREADS="${APACHE_MAX_REQUEST_WORKERS}"
[ "${APACHE_MIN_SPARE_THREADS}" -gt "${APACHE_MAX_SPARE_THREADS}" ] \
    && APACHE_MIN_SPARE_THREADS="${APACHE_MAX_SPARE_THREADS}"

log "apache: ${APACHE_MAX_REQUEST_WORKERS} worker threads" \
    "(${apache_server_limit} x ${APACHE_THREADS_PER_CHILD})," \
    "php-fpm: ${PHP_FPM_MAX_CHILDREN} children, pm=${PHP_FPM_PM}"

# =============================================================================
# Write PHP-FPM overrides
# =============================================================================
fpm_runtime=/usr/local/etc/php-fpm.d/zz-runtime.conf
{
    echo "; Generated by entrypoint.sh — do not edit, changes are overwritten."
    echo "[www]"
    echo "pm = ${PHP_FPM_PM}"
    echo "pm.max_children = ${PHP_FPM_MAX_CHILDREN}"

    case "${PHP_FPM_PM}" in
        dynamic)
            echo "pm.start_servers = ${fpm_start_servers}"
            echo "pm.min_spare_servers = ${fpm_min_spare}"
            echo "pm.max_spare_servers = ${fpm_max_spare}"
            echo "pm.process_idle_timeout = ${PHP_FPM_PROCESS_IDLE_TIMEOUT}"
            ;;
        ondemand)
            echo "pm.process_idle_timeout = ${PHP_FPM_PROCESS_IDLE_TIMEOUT}"
            ;;
        static)
            # All children forked up front: no fork latency under load, at the
            # cost of always holding the full memory footprint.
            ;;
        *)
            warn "unknown PHP_FPM_PM='${PHP_FPM_PM}', expected static|dynamic|ondemand"
            ;;
    esac

    echo "pm.max_requests = ${PHP_FPM_MAX_REQUESTS}"
    echo "pm.status_path = /fpm-status"
    echo "ping.path = /fpm-ping"
    echo "ping.response = pong"
    echo "request_terminate_timeout = ${PHP_FPM_REQUEST_TERMINATE_TIMEOUT}"
    echo "request_slowlog_timeout = ${PHP_FPM_SLOWLOG_TIMEOUT}"

    if [ "${PHP_FPM_ACCESS_LOG}" = "on" ]; then
        # %d is the request duration — the reason to ever turn this on.
        echo 'access.log = /proc/self/fd/2'
        echo 'access.format = "%R - %u %t \"%m %r%Q%q\" %s %{mili}dms %{kilo}MkB %C%%"'
    else
        echo "access.log = /dev/null"
    fi
} > "${fpm_runtime}"

# =============================================================================
# Write php.ini overrides
# =============================================================================
php_runtime=/usr/local/etc/php/conf.d/zzz-runtime.ini
{
    echo "; Generated by entrypoint.sh — do not edit, changes are overwritten."
    echo "memory_limit = ${PHP_MEMORY_LIMIT}"
    echo "max_execution_time = ${PHP_MAX_EXECUTION_TIME}"
    echo "max_input_time = ${PHP_MAX_INPUT_TIME}"
    echo "date.timezone = ${PHP_TIMEZONE}"
    echo "opcache.memory_consumption = ${PHP_OPCACHE_MEMORY}"
    echo "opcache.validate_timestamps = ${PHP_OPCACHE_VALIDATE_TIMESTAMPS}"
    echo "opcache.file_cache = ${PHP_OPCACHE_FILE_CACHE}"

    # Only meaningful when timestamps are validated; setting it otherwise reads
    # like it does something (the old config set both and the pair was
    # contradictory).
    if [ "${PHP_OPCACHE_VALIDATE_TIMESTAMPS}" != "0" ]; then
        echo "opcache.revalidate_freq = ${PHP_OPCACHE_REVALIDATE_FREQ}"
    fi

    case "${PHP_OPCACHE_JIT}" in
        off|Off|OFF|disable|0|"")
            echo "opcache.jit = off"
            echo "opcache.jit_buffer_size = 0"
            ;;
        *)
            # Off by default on purpose: for template-and-database-bound CMS
            # workloads JIT typically changes little and occasionally regresses.
            # Measure before enabling.
            echo "opcache.jit = ${PHP_OPCACHE_JIT}"
            echo "opcache.jit_buffer_size = ${PHP_OPCACHE_JIT_BUFFER_SIZE}"
            ;;
    esac

    if [ -n "${PHP_OPCACHE_PRELOAD}" ]; then
        echo "opcache.preload = ${PHP_OPCACHE_PRELOAD}"
        # Required because the FPM master starts as root; without it PHP refuses
        # to preload at all.
        echo "opcache.preload_user = www-data"
    fi

    echo "session.save_handler = ${PHP_SESSION_HANDLER}"
    echo "session.save_path = \"${PHP_SESSION_PATH}\""

    [ -n "${PHP_EXTRA_INI}" ] && printf '%b\n' "${PHP_EXTRA_INI}"
} > "${php_runtime}"

if [ "${PHP_SESSION_HANDLER}" = "files" ] && [ "${PHP_SESSION_PATH}" = "/tmp" ]; then
    log "sessions are container-local files: they are lost on restart and not" \
        "shared between replicas. Use PHP_SESSION_HANDLER=redis when scaling out."
fi

# =============================================================================
# Write Apache runtime config
# =============================================================================
remoteip_conf=/etc/apache2/runtime.d/remoteip.conf
: > "${remoteip_conf}"

if [ -n "${APACHE_REMOTE_IP_TRUSTED_PROXY}" ]; then
    {
        echo "# Generated by entrypoint.sh"
        echo "RemoteIPHeader ${APACHE_REMOTE_IP_HEADER:-X-Forwarded-For}"
        echo "RemoteIPTrustedProxy ${APACHE_REMOTE_IP_TRUSTED_PROXY}"
    } > "${remoteip_conf}"
    log "mod_remoteip active for proxies: ${APACHE_REMOTE_IP_TRUSTED_PROXY}"
elif [ -n "${APACHE_REMOTE_IP_HEADER}" ]; then
    # Honouring X-Forwarded-For from any source lets a client forge its own IP,
    # defeating rate limits, IP allowlists and the TYPO3 backend IP lock.
    warn "APACHE_REMOTE_IP_HEADER is set but APACHE_REMOTE_IP_TRUSTED_PROXY is" \
         "not — refusing to enable mod_remoteip, as any client could then spoof" \
         "its address. Set the trusted proxy range to enable it."
fi

# =============================================================================
# Prepare runtime directories
# =============================================================================
mkdir -p /var/run/apache2 "${PHP_OPCACHE_FILE_CACHE}"
chown www-data:www-data "${PHP_OPCACHE_FILE_CACHE}"
rm -f "${PHP_FPM_SOCKET}" /var/run/apache2/apache2.pid

# Apache reads ${...} in its config from this environment.
export APACHE_SERVER_NAME APACHE_PORT APACHE_TIMEOUT APACHE_KEEPALIVE \
       APACHE_MAX_KEEPALIVE_REQUESTS APACHE_KEEPALIVE_TIMEOUT APACHE_LOG_LEVEL \
       APACHE_LOG_FORMAT APACHE_ENABLE_SENDFILE APACHE_ENABLE_MMAP \
       APACHE_ALLOW_OVERRIDE APACHE_THREADS_PER_CHILD APACHE_MAX_REQUEST_WORKERS \
       APACHE_MAX_CONNECTIONS_PER_CHILD APACHE_ASYNC_REQUEST_WORKER_FACTOR \
       APACHE_BROTLI APACHE_BROTLI_QUALITY APACHE_DEFLATE_LEVEL \
       APACHE_ASSET_CACHE_MAX_AGE APACHE_PROXY_TIMEOUT \
       APACHE_START_SERVERS APACHE_MIN_SPARE_THREADS APACHE_MAX_SPARE_THREADS \
       PHP_FPM_SOCKET
export APACHE_SERVER_LIMIT="${apache_server_limit}"

# Fail loudly at startup rather than half-serving a broken config.
php-fpm --test
apache2 -t

# =============================================================================
# Start and supervise
# =============================================================================
fpm_pid=""
apache_pid=""
shutting_down=0

# wait_gone PID SECONDS — true once PID has exited (or was never started).
wait_gone() {
    local waited=0
    while kill -0 "$1" 2>/dev/null; do
        [ "${waited}" -ge "$2" ] && return 1
        sleep 1
        waited=$(( waited + 1 ))
    done
    return 0
}

shutdown() {
    if [ "${shutting_down}" = "1" ]; then
        return 0
    fi
    shutting_down=1
    log "shutting down"

    # Apache first: SIGWINCH is graceful-stop — stop accepting, finish in-flight.
    # FPM must keep running until Apache is gone, otherwise requests still
    # queued on the socket are dropped and Apache answers them with 503.
    if [ -n "${apache_pid}" ]; then
        kill -WINCH "${apache_pid}" 2>/dev/null || true
    fi
    wait_gone "${apache_pid}" 20 || true

    # PHP-FPM: SIGQUIT is the graceful shutdown signal.
    if [ -n "${fpm_pid}" ]; then
        kill -QUIT "${fpm_pid}" 2>/dev/null || true
    fi
    if wait_gone "${fpm_pid}" 5 && ! kill -0 "${apache_pid}" 2>/dev/null; then
        return 0
    fi

    warn "graceful shutdown timed out, forcing"
    kill -TERM "${apache_pid}" "${fpm_pid}" 2>/dev/null || true
}
trap shutdown TERM INT QUIT

php-fpm --nodaemonize &
fpm_pid=$!

# Apache used to be started immediately, racing FPM to create the socket, so
# requests arriving during startup got 503s.
for _ in $(seq 1 100); do
    [ -S "${PHP_FPM_SOCKET}" ] && break
    kill -0 "${fpm_pid}" 2>/dev/null || { log "php-fpm died during startup"; wait "${fpm_pid}"; exit 1; }
    sleep 0.1
done

if [ ! -S "${PHP_FPM_SOCKET}" ]; then
    log "php-fpm socket ${PHP_FPM_SOCKET} did not appear within 10s"
    kill -TERM "${fpm_pid}" 2>/dev/null || true
    exit 1
fi

apache2 -DFOREGROUND &
apache_pid=$!

log "ready"

# Whichever process exits first brings the container down. Previously PHP-FPM
# could die and the container stayed "running", serving 503s to every request
# with no restart and no signal to the orchestrator.
set +e
wait -n "${fpm_pid}" "${apache_pid}"
first_exit=$?
set -e

if [ "${shutting_down}" = "0" ]; then
    if ! kill -0 "${fpm_pid}" 2>/dev/null; then
        log "php-fpm exited unexpectedly (status ${first_exit}) — stopping container"
    else
        log "apache exited unexpectedly (status ${first_exit}) — stopping container"
    fi
fi

shutdown
exit "${first_exit}"
