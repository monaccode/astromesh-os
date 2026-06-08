#!/usr/bin/env bash
# A/B rollback gate: boot v1, let the guest auto-update to a deliberately UNHEALTHY v2
# (served over HTTP), and assert the boot-counting rolls back to v1.
# Usage: tests/boot/rollback-and-assert.sh <v1-disk-image>
# Requires: an HTTP server on :8088 serving the BROKEN v2 split artifacts + LATEST=2
# (the caller sets this up — see tests/local/dev-loop.sh / the CI job).
set -euo pipefail

IMAGE="${1:?usage: rollback-and-assert.sh <disk-image>}"
PORT=8000
# 3 trials * (90s health timeout + boot) + final v1 boot. Generous for TCG.
TIMEOUT=600

qemu-img resize "${IMAGE}" +4G >/dev/null

if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[rollback] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars.fd

echo "[rollback] starting QEMU (persistent, reboots allowed)"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > qemu-console.log 2>&1 &
QEMU_PID=$!
trap 'kill ${QEMU_PID} 2>/dev/null || true' EXIT

wait_health() {
    local deadline=$(( $(date +%s) + $1 ))
    until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
        [ "$(date +%s)" -ge "${deadline}" ] && return 1
        sleep 3
    done
}

echo "[rollback] waiting for initial v1 health"
wait_health 180 || { echo "[rollback] FAIL: v1 never came up"; tail -n 120 qemu-console.log; exit 1; }
echo "[rollback] PASS: v1 up before update"

echo "[rollback] waiting for the bad-v2 attempt + rollback to v1 (up to ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
# Success = the unhealthy v2 was tried (boot-check logged an unhealthy reboot) AND the
# system is back to a healthy v1: the LATEST ASTROMESH_BUILD marker is 1 and health 200.
while true; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[rollback] FAIL: did not observe rollback to healthy v1 in time"
        echo "----- boot-check / markers -----"; grep -aE 'boot-check|ASTROMESH_BUILD' qemu-console.log || true
        echo "----- console tail -----"; tail -n 150 qemu-console.log || true
        exit 1
    fi
    grep -q 'boot-check.*UNHEALTHY' qemu-console.log || { sleep 5; continue; }
    last_ver=$(grep -aoE 'ASTROMESH_BUILD=[0-9]+' qemu-console.log | tail -1 | cut -d= -f2)
    [ "${last_ver}" = "1" ] || { sleep 5; continue; }
    curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1 || { sleep 5; continue; }
    break
done
echo "[rollback] PASS: bad v2 was tried, system rolled back to a healthy v1"
echo "[rollback] ROLLBACK GATE PASSED"
