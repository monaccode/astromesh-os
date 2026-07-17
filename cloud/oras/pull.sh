#!/usr/bin/env bash
# Pulls the disk artifact (NOT a container) for provisioning / sysupdate.
# Since v0.7.0 the artifact is zstd-compressed (.raw.zst) and is decompressed here, so
# callers always end up with a .raw. Tags published before that (<= v0.6.0) carry a bare
# .raw and are passed through untouched.
set -euo pipefail

REPO="${ORAS_REPO:?set ORAS_REPO, e.g. docker.io/fulfarodev/astromesh-os}"
TAG="${ORAS_TAG:-latest}"

echo "[oras] pulling ${REPO}:${TAG}"
oras pull "${REPO}:${TAG}"

shopt -s nullglob
for z in *.raw.zst; do
    command -v zstd >/dev/null || { echo "pull.sh: ${z} needs zstd to decompress" >&2; exit 1; }
    echo "[oras] decompressing ${z}"
    # Restores the holes the compressor collapsed, so the .raw lands sparse again.
    zstd -q -f -d --sparse "${z}" -o "${z%.zst}"
    rm -f "${z}"
done
shopt -u nullglob

echo "[oras] done — the .raw is now in the current directory"
