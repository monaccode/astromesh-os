#!/usr/bin/env bash
# Boots the Phase 0 qcow2 in QEMU and asserts the boot-to-agent gate.
# Usage: tests/boot/run-and-assert.sh <path-to-disk-image>
set -euo pipefail

IMAGE="${1:?usage: run-and-assert.sh <disk-image>}"
# Phase 2a: systemd-repart creates /var in free space on first boot, so the disk
# needs headroom beyond the minimized image.
qemu-img resize "${IMAGE}" +3G >/dev/null
PORT=8000
BOOT_TIMEOUT=180
AGENT="phase0-smoke"

KVM_FLAG=""
if [ -w /dev/kvm ]; then KVM_FLAG="-enable-kvm"; fi

# The image boots via systemd-boot (UEFI), so QEMU needs OVMF firmware. Use a
# writable copy of the vars store. Paths differ across distros — probe for them
# with a plain loop (ls under `set -e -o pipefail` aborts when a path is absent).
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    if [ -f "$c" ]; then OVMF_CODE="$c"; break; fi
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    if [ -f "$v" ]; then OVMF_VARS_SRC="$v"; break; fi
done
if [ -z "${OVMF_CODE}" ] || [ -z "${OVMF_VARS_SRC}" ]; then
    echo "[boot] FAIL: OVMF firmware not found (install the 'ovmf' package)"
    exit 1
fi
cp "${OVMF_VARS_SRC}" ovmf_vars.fd
echo "[boot] OVMF_CODE=${OVMF_CODE}"

echo "[boot] starting QEMU (image=${IMAGE}, kvm=${KVM_FLAG:-none})"
qemu-system-x86_64 \
    ${KVM_FLAG} \
    -machine q35 \
    -m 2048 -smp 2 \
    -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > qemu-console.log 2>&1 &
QEMU_PID=$!
trap 'kill ${QEMU_PID} 2>/dev/null || true' EXIT

echo "[boot] waiting for /v1/health (timeout ${BOOT_TIMEOUT}s)"
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[boot] FAIL: /v1/health did not respond in time"
        echo "----- kernel command line -----"; grep -a -m1 'Kernel command line' qemu-console.log || echo "(cmdline not captured)"
        echo "----- qemu-console.log (head) -----"; head -n 80 qemu-console.log || true
        echo "----- qemu-console.log (tail) -----"; tail -n 200 qemu-console.log || true
        exit 1
    fi
    sleep 3
done
echo "[boot] PASS: /v1/health is 200"

echo "[boot] running agent ${AGENT}"
# Capture status + body separately (no -f) so a provider/runtime error surfaces its detail
# instead of just "curl: (22) ... 502". On failure, dump the body and the in-VM journal
# (forwarded to the console) — that carries the actual cause (DNS, auth, model, …).
HTTP=$(curl -sS -o /tmp/agent-resp.json -w '%{http_code}' -X POST "http://localhost:${PORT}/v1/agents/${AGENT}/run" \
    -H 'Content-Type: application/json' \
    -d '{"query":"ping"}' || true)
RESP=$(cat /tmp/agent-resp.json 2>/dev/null || true)
if [ "${HTTP}" != "200" ] || [ -z "${RESP}" ]; then
    echo "[boot] FAIL: agent run returned HTTP ${HTTP}"
    echo "----- agent response body -----"; echo "${RESP}"
    echo "----- qemu-console.log (tail) -----"; tail -n 200 qemu-console.log || true
    exit 1
fi
echo "[boot] agent response: ${RESP}"
echo "[boot] PASS: agent returned a non-empty 200 response"

echo "[boot] doctor (informational):"
curl -fsS "http://localhost:${PORT}/v1/system/doctor" || echo "[boot] (doctor unavailable)"

echo "[boot] asserting immutability marker"
if grep -q "IMMUTABILITY OK" qemu-console.log; then
    echo "[boot] PASS: IMMUTABILITY OK"
else
    echo "[boot] FAIL: immutability marker not found"
    echo "----- immutability lines -----"; grep -i 'IMMUTABILITY' qemu-console.log || true
    exit 1
fi

echo "[boot] GATE PASSED"
