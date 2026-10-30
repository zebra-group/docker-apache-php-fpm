#!/usr/bin/env bash
#
# Unit tests for .github/scripts/trivy-db-download.sh, run against a stub
# `trivy` on PATH — no network, no Docker.
#
#   test/trivy-db-download-test.sh
#
# The stub fails for every repository listed in STUB_FAIL_REPOS and logs each
# call, so the tests can assert on the order of attempts.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/.github/scripts/trivy-db-download.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin"
cat > "${work}/bin/trivy" <<'STUB'
#!/usr/bin/env bash
repo=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--db-repository" ]; then repo="$2"; fi
    shift
done
echo "${repo}" >> "${STUB_LOG}"
for failing in ${STUB_FAIL_REPOS:-}; do
    [ "${repo}" = "${failing}" ] && exit 1
done
exit 0
STUB
chmod +x "${work}/bin/trivy"

export PATH="${work}/bin:${PATH}"
export STUB_LOG="${work}/calls.log"
export TRIVY_DB_REPOSITORIES="primary secondary"
export TRIVY_DB_ATTEMPTS=2
export TRIVY_DB_RETRY_DELAY=0

failures=0
run_case() {
    local name="$1" fail_repos="$2" want_exit="$3" want_calls="$4"
    : > "${STUB_LOG}"
    local got_exit=0
    STUB_FAIL_REPOS="${fail_repos}" "${script}" "${work}/cache" > /dev/null 2>&1 || got_exit=$?
    local got_calls
    got_calls="$(paste -sd' ' "${STUB_LOG}")"
    if [ "${got_exit}" = "${want_exit}" ] && [ "${got_calls}" = "${want_calls}" ]; then
        echo "ok   ${name}"
    else
        echo "FAIL ${name}: exit ${got_exit} (want ${want_exit}), calls '${got_calls}' (want '${want_calls}')"
        failures=$(( failures + 1 ))
    fi
}

run_case "primary works: one call, no fallback"  ""                  0 "primary"
run_case "primary down: falls back to secondary" "primary"           0 "primary secondary"
run_case "both down: retries, then fails"        "primary secondary" 1 "primary secondary primary secondary"

if "${script}" > /dev/null 2>&1; then
    echo "FAIL missing argument: expected non-zero exit"
    failures=$(( failures + 1 ))
else
    echo "ok   missing argument is rejected"
fi

[ "${failures}" -eq 0 ]
