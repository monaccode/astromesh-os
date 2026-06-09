#!/usr/bin/env bash
# Fase 3.6 gate. Boot 1 (enroll + positive): SecureBoot OVMF in setup-mode (empty vars) ->
# systemd-boot auto-enrolls our keys (secure-boot-enroll force) -> reboots -> SB active -> the
# signed UKI boots -> /v1/health 200 and [secureboot] SB-ENABLED OK on the console. The enrolled
# OVMF vars are persisted. Boot 2 (negative): same enrolled vars, a disk whose signed UKI has one
# flipped byte -> the firmware must REFUSE it -> /v1/health never comes up.
# Usage: secureboot-and-assert.sh <v1-raw-image>
set -euo pipefail
RAW="${1:?usage: secureboot-and-assert.sh <v1-raw-image>}"
PORT=8000
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/lib-esp.sh"

# SecureBoot-capable OVMF firmware (CODE) is REQUIRED for this gate.
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
[ -n "${OVMF_CODE}" ] || { echo "[secureboot] FAIL: no SecureBoot OVMF CODE (install ovmf)"; exit 1; }
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_VARS_SRC}" ] || { echo "[secureboot] FAIL: no OVMF VARS template"; exit 1; }

if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi

# Stage the ESP for unattended enrollment, then build the good (signed) disk.
esp_set_secureboot_enroll "${RAW}"
qemu-img convert -O qcow2 "${RAW}" sb.qcow2
qemu-img resize sb.qcow2 +3G >/dev/null
cp "${OVMF_VARS_SRC}" ovmf_vars_sb.fd                 # setup-mode vars (no keys yet)

# --- Boot 1: enroll (setup-mode -> systemd-boot enrolls -> reboot -> SB active) + positive ---
echo "[secureboot] boot 1: enroll keys + boot the signed UKI under Secure Boot"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -global ICH9-LPC.disable_s3=1 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_sb.fd \
    -drive file=sb.qcow2,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > sb-console1.log 2>&1 &
QPID=$!
trap 'kill ${QPID} 2>/dev/null || true' EXIT
deadline=$(( $(date +%s) + 300 ))   # generous: enroll + reboot + boot, slow under TCG
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[secureboot] FAIL: signed UKI never reached /v1/health under SB"; tail -n 150 sb-console1.log; exit 1
    fi
    sleep 3
done
grep -aq 'secureboot\] SB-ENABLED OK' sb-console1.log || {
    echo "[secureboot] FAIL: SB-ENABLED OK marker absent — booted but Secure Boot not active";
    grep -aE 'secureboot\]' sb-console1.log | tail; exit 1; }
echo "[secureboot] PASS: keys enrolled, Secure Boot active, signed UKI healthy"
kill ${QPID} 2>/dev/null || true; wait ${QPID} 2>/dev/null || true

# --- Boot 2: negative — corrupt the signed UKI; the firmware must refuse it ---
echo "[secureboot] boot 2: byte-flipped UKI must be rejected by the firmware"
qemu-img convert -O raw "${RAW}" sb-bad.raw
esp_set_secureboot_enroll "sb-bad.raw"   # keep loader.conf consistent with the good disk
esp_flip_uki_byte "sb-bad.raw"
qemu-img convert -O qcow2 sb-bad.raw sb-bad.qcow2
qemu-img resize sb-bad.qcow2 +3G >/dev/null
deadline=$(( $(date +%s) + 120 ))
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -global ICH9-LPC.disable_s3=1 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_sb.fd \
    -drive file=sb-bad.qcow2,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::$((PORT+1))-:${PORT} \
    > sb-console2.log 2>&1 &
QPID2=$!
trap 'kill ${QPID} ${QPID2} 2>/dev/null || true' EXIT
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if curl -fsS "http://localhost:$((PORT+1))/v1/health" >/dev/null 2>&1; then
        echo "[secureboot] FAIL: corrupted UKI BOOTED to health — Secure Boot did not enforce"
        tail -n 80 sb-console2.log; kill ${QPID2} 2>/dev/null || true; exit 1
    fi
    sleep 3
done
kill ${QPID2} 2>/dev/null || true; wait ${QPID2} 2>/dev/null || true
echo "[secureboot] PASS: corrupted UKI was rejected (never reached health)"
echo "[secureboot] SECUREBOOT GATE PASSED"
