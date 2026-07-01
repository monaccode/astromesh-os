#!/usr/bin/env bash
# Pulls the disk artifact (NOT a container) for provisioning / sysupdate.
set -euo pipefail

REPO="${ORAS_REPO:?set ORAS_REPO, e.g. docker.io/fulfarodev/astromesh-os}"
TAG="${ORAS_TAG:-latest}"

echo "[oras] pulling ${REPO}:${TAG}"
oras pull "${REPO}:${TAG}"
echo "[oras] done — the .raw is now in the current directory"
