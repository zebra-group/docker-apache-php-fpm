#!/bin/sh
#
# Prints a fingerprint of the Debian package indices a base image resolves
# against: bookworm/trixie, -updates and -security, for the host architecture.
#
#   .github/scripts/apt-index-fingerprint.sh php:8.4-fpm
#
# The build passes this into the Dockerfile as APT_INDEX_FINGERPRINT, which
# keys the apt-get layer. With a warm cache that layer is otherwise never
# re-run, so a Debian security update published mid-week stayed out of the
# image until the Sunday no-cache build. Now the layer rebuilds exactly when
# Debian publishes something, and stays cached when it did not.
#
# The indices are hashed decompressed: Debian images store them as .lz4, and
# hashing the raw files would tie the fingerprint to the compression format
# rather than to the package versions. InRelease is deliberately left out — it
# is re-signed on a schedule and would change without any package changing.
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <base-image>" >&2
    exit 2
fi

# bash, not sh: without pipefail a failing cat-file would silently yield the
# hash of an empty stream — a stable fingerprint that never busts the cache.
docker run --rm --pull always --entrypoint bash "$1" -c '
    set -euo pipefail
    apt-get update -qq >/dev/null
    mapfile -t indices < <(apt-get indextargets --format "\$(FILENAME)" "Created-By: Packages" | sort)
    if [ "${#indices[@]}" -eq 0 ]; then
        echo "no Packages indices found after apt-get update" >&2
        exit 1
    fi
    for f in "${indices[@]}"; do /usr/lib/apt/apt-helper cat-file "$f"; done \
        | sha256sum | cut -d" " -f1
'
