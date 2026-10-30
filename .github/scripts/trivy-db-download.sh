#!/usr/bin/env bash
#
# Downloads the Trivy vulnerability DB into a cache directory, retrying with
# backoff and falling back to a second registry.
#
#   .github/scripts/trivy-db-download.sh "$GITHUB_WORKSPACE/.cache/trivy"
#
# Trivy fetches its DB on every scan, and a failed fetch is fatal before any
# image is looked at. A single 404 from mirror.gcr.io (30.10.2026) failed one
# matrix job, which skipped the merge job and published no tag at all that
# night. Trivy's own --db-repository fallback does not help there: it only moves
# to the next registry on errors it classes as temporary, and a 404 is not one.
#
# Scans run afterwards with --skip-db-update, so they never touch the network
# for the DB again.
#
# Overridable for tests: TRIVY_DB_REPOSITORIES (space-separated, in order),
# TRIVY_DB_ATTEMPTS, TRIVY_DB_RETRY_DELAY (seconds, multiplied by the attempt).
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <cache-dir>" >&2
    exit 2
fi
cache_dir="$1"

read -r -a repos <<< "${TRIVY_DB_REPOSITORIES:-mirror.gcr.io/aquasec/trivy-db:2 ghcr.io/aquasecurity/trivy-db:2}"
attempts="${TRIVY_DB_ATTEMPTS:-3}"
delay="${TRIVY_DB_RETRY_DELAY:-30}"

for attempt in $(seq 1 "${attempts}"); do
    for repo in "${repos[@]}"; do
        if trivy image --download-db-only --no-progress \
             --cache-dir "${cache_dir}" --db-repository "${repo}"; then
            echo "Trivy DB downloaded from ${repo} (attempt ${attempt}/${attempts})"
            exit 0
        fi
        echo "::warning::Trivy DB download from ${repo} failed (attempt ${attempt}/${attempts})"
    done
    if [ "${attempt}" -lt "${attempts}" ]; then
        sleep $(( attempt * delay ))
    fi
done

echo "::error::Trivy DB could not be downloaded from any of: ${repos[*]}" >&2
exit 1
