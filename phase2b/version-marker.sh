#!/usr/bin/env bash
# Logs the baked image version to the console so the multi-boot harness can tell
# which version is running (e.g. ASTROMESH_BUILD=1 before update, =2 after).
set -uo pipefail
ver="$(cat /usr/lib/astromesh-os/build-version 2>/dev/null || echo unknown)"
echo "ASTROMESH_BUILD=${ver}"
