#!/usr/bin/env bash
# Publishes the Phase 1 disk image as an OCI ARTIFACT (not a container) via ORAS.
# The artifact is a disk — consume it with `oras pull` + provisioning, never
# `docker run`/`docker pull`.
set -euo pipefail

REPO="${ORAS_REPO:?set ORAS_REPO, e.g. docker.io/monaccode/astromesh-os}"
TAG="${ORAS_TAG:?set ORAS_TAG, e.g. 0.1.0}"
RAW="${1:?usage: push.sh <disk.raw>}"
MEDIA="application/vnd.astromesh.disk.raw"

[ -f "${RAW}" ] || { echo "push.sh: no such file: ${RAW}" >&2; exit 1; }

echo "[oras] pushing ${RAW} -> ${REPO}:${TAG} (${MEDIA})"
oras push "${REPO}:${TAG}" "${RAW}:${MEDIA}"
oras push "${REPO}:latest" "${RAW}:${MEDIA}"
echo "[oras] done"
