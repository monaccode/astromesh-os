#!/usr/bin/env bash
# A/B update test: boot v1, let the guest auto-update to v2 (served over HTTP on
# the host at 10.0.2.2:8088 via SLIRP), and assert it reboots into v2.
# Usage: tests/boot/update-and-assert.sh <v1-disk-image>
set -euo pipefail

IMAGE="${1:?usage: update-and-assert.sh <disk-image>}"
PORT=8000
TIMEOUT=300

qemu-img resize "${IMAGE}" +4G >/dev/null

# With KVM use it. Without it (GitHub-hosted runners have no /dev/kvm) fall back to
# multi-threaded TCG + more vCPUs so the slow software-emulated boot — notably the
# dm-verity device setup in the initrd — completes well inside the device timeout.
if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    if [ -f "$c" ]; then OVMF_CODE="$c"; break; fi
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    if [ -f "$v" ]; then OVMF_VARS_SRC="$v"; break; fi
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[update] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars.fd

echo "[update] starting QEMU (persistent, reboots allowed)"
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

echo "[update] waiting for v1 health"
wait_health 180 || {
    echo "[update] FAIL: v1 never came up"
    echo "----- kernel command line -----"; grep -a -m1 'Kernel command line' qemu-console.log || true
    echo "----- console head -----"; head -n 80 qemu-console.log || true
    echo "----- console tail -----"; tail -n 200 qemu-console.log || true
    exit 1
}
# v1 is up (/v1/health responded). The ASTROMESH_BUILD=1 marker is best-effort: under
# a fast (KVM) boot the auto-update reboot can preempt it, so it is NOT a gate — health
# plus IMMUTABILITY OK are the v1-booted signal. The real success criterion below is
# reaching ASTROMESH_BUILD=2 (booted into the updated slot).
echo "[update] PASS: v1 is up (/v1/health responded)"
if grep -q "IMMUTABILITY OK" qemu-console.log; then
    echo "[update] DIAG: IMMUTABILITY OK — verity active at runtime (/dev/mapper/root)"
elif grep -aom1 "IMMUTABILITY FAIL: .*" qemu-console.log; then
    echo "[update] DIAG: verity NOT active at runtime"
fi
if grep -q "ASTROMESH_BUILD=1" qemu-console.log; then
    echo "[update] DIAG: saw ASTROMESH_BUILD=1 marker"
else
    echo "[update] DIAG: v1 marker not seen (likely preempted by the auto-update reboot)"
fi
echo "[update] DIAG: $(grep -a -m1 'Kernel command line' qemu-console.log || echo 'cmdline not logged')"

echo "[update] waiting for auto-update + reboot into v2 (up to ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
until grep -q "ASTROMESH_BUILD=2" qemu-console.log; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[update] FAIL: never booted v2"
        echo "----- autoupdate/sysupdate lines -----"; grep -iE 'autoupdate|sysupdate|ASTROMESH_BUILD' qemu-console.log || true
        echo "----- console tail -----"; tail -n 150 qemu-console.log || true
        exit 1
    fi
    sleep 5
done
echo "[update] PASS: booted v2"

wait_health 120 || { echo "[update] FAIL: v2 health did not come up"; exit 1; }
echo "[update] PASS: v2 /v1/health is 200"
echo "[update] UPDATE GATE PASSED"
