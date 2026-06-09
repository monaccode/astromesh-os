#!/usr/bin/env bash
# Fase 3.5 gate: boot the image, assert astromeshd is functional UNDER the egress filter
# (/v1/health 200 via hostfwd — proves the allowlist did not break ingress/health or the loopback
# stub), then assert the in-guest self-check passed ([egress] EGRESS GATE OK on the console:
# POLICY-ACTIVE + POSITIVE-ALLOW + POSITIVE-BLOCK).
# Usage: egress-and-assert.sh <disk-image>
set -euo pipefail

IMAGE="${1:?usage: egress-and-assert.sh <disk-image>}"
PORT=8000
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
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[egress] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars_egress.fd

echo "[egress] starting QEMU"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_egress.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > egress-console.log 2>&1 &
QPID=$!
trap 'kill ${QPID} 2>/dev/null || true' EXIT

echo "[egress] waiting for /v1/health (timeout 240s) — proves the allowlist didn't break health/ingress"
deadline=$(( $(date +%s) + 240 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[egress] FAIL: /v1/health never came up under the egress filter"; tail -n 120 egress-console.log; exit 1
    fi
    sleep 3
done
echo "[egress] PASS: /v1/health 200 under the egress filter"

echo "[egress] asserting in-guest egress self-check marker"
deadline=$(( $(date +%s) + 60 ))
until grep -aq 'egress\] EGRESS GATE OK' egress-console.log; do
    if grep -aq 'egress\] EGRESS FAILED' egress-console.log; then
        echo "[egress] FAIL: self-check reported EGRESS FAILED"
        grep -aE 'egress\]' egress-console.log | tail -20; exit 1
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[egress] FAIL: egress self-check marker not seen"
        grep -aE 'egress\]' egress-console.log | tail -20; exit 1
    fi
    sleep 3
done
echo "[egress] PASS: egress self-check (policy-active + positive-allow + positive-block)"
echo "[egress] EGRESS GATE PASSED"
