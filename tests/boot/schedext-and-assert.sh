#!/usr/bin/env bash
# §12.2a gate: boot ONE VM with a `sched_ext: true` machine-config (flips spec.sched_ext.enabled). The
# in-guest astromesh-schedext loader runs an scx scheduler and the self-check asserts the kernel supports
# sched_ext, a custom scheduler is ACTIVE, and astromeshd is functional under it. This host-side gate
# boots and greps for `SCHEDEXT GATE OK`.
set -euo pipefail
IMAGE="${1:?usage: schedext-and-assert.sh <v1-raw-image>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/lib-smbios.sh"
source "${HERE}/lib-swtpm.sh"

PORT=8000
if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi
OVMF_CODE=""; for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""; for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[schedext] FAIL: OVMF not found"; exit 1; }

TPM="$(mktemp -d)/t"; QPID=""
cleanup() { kill ${QPID} 2>/dev/null || true; SWTPM_DIR="${TPM}" swtpm_stop 2>/dev/null || true; }
trap cleanup EXIT

disk="schedext.qcow2"; vars="ovmf_vars_schedext.fd"; CON="schedext-console.log"
qemu-img convert -O qcow2 "${IMAGE}" "${disk}"; qemu-img resize "${disk}" +3G >/dev/null
cp "${OVMF_VARS_SRC}" "${vars}"
swtpm_start "${TPM}"

CRED_YAML="profile: worker
node_id: schedext-node
sched_ext: true"

# shellcheck disable=SC2046
qemu-system-x86_64 ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -global ICH9-LPC.disable_s3=1 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file="${vars}" \
    -drive file="${disk}",format=qcow2,if=virtio \
    $(swtpm_qemu_args) \
    -smbios "$(smbios_machine_config "${CRED_YAML}")" \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:8000 \
    > "${CON}" 2>&1 &
QPID=$!

echo "[schedext] waiting for /v1/health (timeout 420s)"
deadline=$(( $(date +%s) + 420 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[schedext] FAIL: /v1/health never came up"; tail -n 120 "${CON}"; exit 1
    fi
    sleep 3
done

echo "[schedext] asserting the in-guest sched_ext self-check (SUPPORTED + ACTIVE + FUNCTIONAL)"
deadline=$(( $(date +%s) + 180 ))
until grep -aqE 'schedext\] SCHEDEXT GATE OK' "${CON}"; do
    if grep -aqE 'schedext\] SCHEDEXT FAILED' "${CON}"; then
        echo "[schedext] FAIL: in-guest self-check reported SCHEDEXT FAILED"
        grep -aE 'schedext\]' "${CON}" | tail -n 40; exit 1
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[schedext] FAIL: SCHEDEXT GATE OK not seen"
        grep -aE 'schedext\]' "${CON}" | tail -n 40; exit 1
    fi
    sleep 3
done
echo "[schedext] custom scheduler ACTIVE + astromeshd FUNCTIONAL under it"
echo "[schedext] SCHEDEXT GATE PASSED"
