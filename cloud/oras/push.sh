#!/usr/bin/env bash
# Publishes the Phase 1 disk image as an OCI ARTIFACT (not a container) via ORAS.
# The artifact is a disk — consume it with `oras pull` + provisioning, never
# `docker run`/`docker pull`.
#
# The disk is pushed zstd-compressed. mkosi emits a sparse .raw: ~1.8G apparent, but only
# ~378M of real blocks — the rest is holes (the empty A/B spare root, var, and slack in
# root-A). ORAS does not preserve sparseness, so pushing the .raw verbatim materialised
# every hole and uploaded ~1880M, of which ~1.5G was zeros. Compressing first collapses
# them (measured: 1880M -> ~406M). The remainder barely compresses — the UKI and the verity
# hash tree are already-compressed/high-entropy — so the win is the holes, not the content.
set -euo pipefail

REPO="${ORAS_REPO:?set ORAS_REPO, e.g. docker.io/fulfarodev/astromesh-os}"
TAG="${ORAS_TAG:?set ORAS_TAG, e.g. 0.1.0}"
RAW="${1:?usage: push.sh <disk.raw>}"
MEDIA="application/vnd.astromesh.disk.raw+zstd"
ZSTD_LEVEL="${ZSTD_LEVEL:-9}"
# `latest` tracks the newest RELEASE (see media-types.md), so only a tag build may move it.
# This used to be an unconditional second push, which meant a workflow_dispatch run — tagged
# `dev` — silently repointed `latest` at a throwaway dev build.
PUSH_LATEST="${PUSH_LATEST:-0}"

[ -f "${RAW}" ] || { echo "push.sh: no such file: ${RAW}" >&2; exit 1; }
command -v zstd >/dev/null || { echo "push.sh: zstd not installed" >&2; exit 1; }

ART="$(basename "${RAW}").zst"
echo "[oras] compressing ${RAW} -> ${ART} (zstd -${ZSTD_LEVEL})"
# -T0 uses every core. Written into the cwd so the pushed artifact is named
# <disk>.raw.zst regardless of where the .raw lives.
zstd -q -f -T0 "-${ZSTD_LEVEL}" "${RAW}" -o "${ART}"
echo "[oras] size: $(du -h "${RAW}" | cut -f1) apparent -> $(du -h "${ART}" | cut -f1) compressed"

echo "[oras] pushing ${ART} -> ${REPO}:${TAG} (${MEDIA})"
oras push "${REPO}:${TAG}" "${ART}:${MEDIA}"
if [ "${PUSH_LATEST}" = "1" ]; then
    echo "[oras] pushing ${ART} -> ${REPO}:latest"
    oras push "${REPO}:latest" "${ART}:${MEDIA}"
else
    echo "[oras] not moving :latest (PUSH_LATEST=${PUSH_LATEST} — not a release build)"
fi
echo "[oras] done"
