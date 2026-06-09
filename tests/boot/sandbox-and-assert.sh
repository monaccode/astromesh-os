#!/usr/bin/env bash
# Fase 3.4 gate: boot the image, assert astromeshd is functional UNDER the sandbox
# (/v1/health 200), then assert the in-guest self-check passed ([sandbox] SANDBOX GATE OK on
# the console: seccomp-filtered + no-new-privs + namespace POSITIVE-BLOCK).
# Usage: sandbox-and-assert.sh <disk-image>
set -euo pipefail

IMAGE="${1:?usage: sandbox-and-assert.sh <disk-image>}"
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
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[sandbox] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars_sandbox.fd

echo "[sandbox] starting QEMU"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_sandbox.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > sandbox-console.log 2>&1 &
QPID=$!
trap 'kill ${QPID} 2>/dev/null || true' EXIT

echo "[sandbox] waiting for /v1/health (timeout 240s) — proves the sandbox didn't break the runtime"
deadline=$(( $(date +%s) + 240 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[sandbox] FAIL: /v1/health never came up under the sandbox"; tail -n 120 sandbox-console.log; exit 1
    fi
    sleep 3
done
echo "[sandbox] PASS: /v1/health 200 under the sandbox"

echo "[sandbox] asserting in-guest sandbox self-check marker"
deadline=$(( $(date +%s) + 60 ))
until grep -aq 'sandbox\] SANDBOX GATE OK' sandbox-console.log; do
    if grep -aq 'sandbox\] SANDBOX FAILED' sandbox-console.log; then
        echo "[sandbox] FAIL: self-check reported SANDBOX FAILED"
        grep -aE 'sandbox\]' sandbox-console.log | tail -20; exit 1
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[sandbox] FAIL: sandbox self-check marker not seen"
        grep -aE 'sandbox\]' sandbox-console.log | tail -20; exit 1
    fi
    sleep 3
done
echo "[sandbox] PASS: sandbox self-check (seccomp + no-new-privs + namespace positive-block)"
echo "[sandbox] SANDBOX GATE PASSED"
