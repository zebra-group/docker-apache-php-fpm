#!/usr/bin/env bash
#
# Container healthcheck.
#
# Probes PHP-FPM's ping endpoint *through Apache*, so a single check covers the
# whole request path: Apache is listening, the Unix socket exists, and FPM has a
# worker available to answer. Checking only that Apache responds would report
# healthy while every PHP request returns 503 — which is exactly the failure the
# image previously had no way to detect.
#
set -euo pipefail

# The status endpoints only exist on the loopback-only status listener.
port="${APACHE_STATUS_PORT:-8081}"

response="$(curl --fail --silent --show-error --max-time 4 \
                 "http://127.0.0.1:${port}/fpm-ping" 2>&1)" || {
    echo "php-fpm ping via apache failed: ${response}" >&2
    exit 1
}

if [ "${response}" != "pong" ]; then
    echo "unexpected ping response: '${response}'" >&2
    exit 1
fi

exit 0
