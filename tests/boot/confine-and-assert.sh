#!/usr/bin/env bash
# Fase 3.2 gate: boot the image, assert astromeshd is functional under confinement
# (/v1/health 200 + an agent query), then assert the in-guest self-check passed
# ([confine] CONFINE GATE OK on the console: confined-enforce + no-denials + positive-block).
# Usage: confine-and-assert.sh <disk-image>
set -euo pipefail

IMAGE="${1:?usage: confine-and-assert.sh <disk-image>}"
PORT=8000
AGENT="phase0-smoke"
qemu-img resize "${IMAGE}" +3G >/dev/null

if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[confine] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars_confine.fd

echo "[confine] starting QEMU"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_confine.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > confine-console.log 2>&1 &
QPID=$!
trap 'kill ${QPID} 2>/dev/null || true' EXIT

echo "[confine] waiting for /v1/health (timeout 240s)"
deadline=$(( $(date +%s) + 240 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[confine] FAIL: /v1/health never came up under confinement"; tail -n 120 confine-console.log; exit 1
    fi
    sleep 3
done
echo "[confine] PASS: /v1/health 200"

echo "[confine] querying agent ${AGENT}"
resp=$(curl -fsS -X POST "http://localhost:${PORT}/v1/agents/${AGENT}/run" \
    -H 'Content-Type: application/json' -d '{"query":"ping"}' 2>/dev/null || true)
[ -n "${resp}" ] || { echo "[confine] FAIL: empty agent response"; tail -n 80 confine-console.log; exit 1; }
echo "[confine] PASS: agent responded (${resp:0:60}...)"

echo "[confine] asserting in-guest confinement self-check marker"
deadline=$(( $(date +%s) + 60 ))
until grep -aq 'confine\] CONFINE GATE OK' confine-console.log; do
    if grep -aq 'confine\] CONFINE FAILED' confine-console.log; then
        echo "[confine] FAIL: self-check reported CONFINE FAILED"
        grep -aE 'confine\]' confine-console.log | tail -20; exit 1
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[confine] FAIL: confinement self-check marker not seen"
        grep -aE 'confine\]' confine-console.log | tail -20; exit 1
    fi
    sleep 3
done
echo "[confine] PASS: confinement self-check (confined-enforce + no-denials + positive-block)"
echo "[confine] CONFINE GATE PASSED"
