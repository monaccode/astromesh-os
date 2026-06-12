#!/usr/bin/env bash
# §12.3 gate: boot the standard image, assert astromeshd is functional WITH the always-on memory
# governance (/v1/health 200 — which also proves the fail-closed memory self-check passed, since
# astromeshd Requires= it), then assert the in-guest self-check markers on the console: MemoryAccounting +
# a finite MemoryMax + OOMPolicy=kill, and the POSITIVE-OOM containment.
# Usage: memory-oom-and-assert.sh <qcow2-disk-image>
set -euo pipefail

IMAGE="${1:?usage: memory-oom-and-assert.sh <disk-image>}"
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
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[memory] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars_memory.fd

echo "[memory] starting QEMU"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_memory.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > memory-console.log 2>&1 &
QPID=$!
trap 'kill ${QPID} 2>/dev/null || true' EXIT

echo "[memory] waiting for /v1/health (timeout 240s) — proves memory governance didn't break the runtime"
deadline=$(( $(date +%s) + 240 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[memory] FAIL: /v1/health never came up under memory governance"; tail -n 120 memory-console.log; exit 1
    fi
    sleep 3
done
echo "[memory] PASS: /v1/health 200 (astromeshd started -> the fail-closed memory self-check passed)"

echo "[memory] asserting in-guest memory self-check marker"
deadline=$(( $(date +%s) + 60 ))
until grep -aq 'memory\] MEMORY GATE OK' memory-console.log; do
    if grep -aq 'memory\] MEMORY FAILED' memory-console.log; then
        echo "[memory] FAIL: self-check reported MEMORY FAILED"
        grep -aE 'memory\]' memory-console.log | tail -20; exit 1
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[memory] FAIL: memory self-check marker not seen"
        grep -aE 'memory\]' memory-console.log | tail -20; exit 1
    fi
    sleep 3
done
echo "[memory] PASS: memory self-check (accounting + finite MemoryMax + OOMPolicy=kill + POSITIVE-OOM)"
echo "[memory] MEMORY GATE PASSED"
