#!/usr/bin/env bash
# Fase 3.1 gate: assert the no-shell posture and the interactive break-glass path.
# Usage: noshell-and-assert.sh <raw-image> <breakglass-password>
# 1. Boot normally, assert the [hardening] NO-SHELL OK console marker (no usable login).
# 2. Run the pexpect driver to prove break-glass: rescue -> sulogin -> root shell (uid=0).
set -euo pipefail

RAW="${1:?usage: noshell-and-assert.sh <raw-image> <password>}"
PASSWORD="${2:?usage: noshell-and-assert.sh <raw-image> <password>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/lib-esp.sh"

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[noshell] FAIL: OVMF not found"; exit 1; }

# Enable an interruptible boot menu on the raw image's ESP, then convert to qcow2.
esp_set_loader_timeout "${RAW}" 20
qemu-img convert -O qcow2 "${RAW}" noshell.qcow2
qemu-img resize noshell.qcow2 +2G >/dev/null

# --- Assertion 1: no-shell marker on a normal boot ---
cp "${OVMF_VARS_SRC}" ovmf_vars_noshell.fd
echo "[noshell] boot 1: asserting NO-SHELL OK marker"
timeout 180 qemu-system-x86_64 \
    -machine q35 -m 2048 -smp 2 -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_noshell.fd \
    -drive file=noshell.qcow2,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci \
    > noshell-console.log 2>&1 &
QPID=$!
trap 'kill ${QPID} 2>/dev/null || true' EXIT
deadline=$(( $(date +%s) + 150 ))
until grep -aq 'hardening\] NO-SHELL OK' noshell-console.log; do
    if grep -aq 'NO-SHELL FAILED' noshell-console.log; then
        echo "[noshell] FAIL: self-check reported NO-SHELL FAILED"; tail -n 80 noshell-console.log; exit 1
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[noshell] FAIL: NO-SHELL OK marker not seen in time"; tail -n 120 noshell-console.log; exit 1
    fi
    sleep 3
done
echo "[noshell] PASS: NO-SHELL OK"
# Confirm break-glass was configured for this (gate) build.
grep -aq 'BREAK-GLASS=configured' noshell-console.log || { echo "[noshell] FAIL: break-glass not configured in gate build"; exit 1; }
kill ${QPID} 2>/dev/null || true; wait ${QPID} 2>/dev/null || true

# --- Assertion 2: interactive break-glass ---
echo "[noshell] boot 2: interactive break-glass via rescue + sulogin"
cp "${OVMF_VARS_SRC}" ovmf_vars_bg.fd
python3 "${HERE}/breakglass-driver.py" noshell.qcow2 "${OVMF_CODE}" ovmf_vars_bg.fd "${PASSWORD}"
echo "[noshell] PASS: break-glass root shell (uid=0)"
echo "[noshell] NO-SHELL GATE PASSED"
