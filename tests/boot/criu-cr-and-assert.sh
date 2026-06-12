#!/usr/bin/env bash
# §12.7 gate: boot ONE VM with a `criu: true` machine-config (flips spec.criu.enabled). The in-guest
# astromesh-criu-gate oneshot runs the C/R cycle (dump --leave-running -> systemctl stop astromeshd ->
# restore -d) and asserts uptime continuity + a post-restore agent run, printing CRIU markers to the
# console. This host-side gate just boots and greps for `CRIU C/R GATE PASSED`.
set -euo pipefail
IMAGE="${1:?usage: criu-cr-and-assert.sh <v1-raw-image>}"
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
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[criu] FAIL: OVMF not found"; exit 1; }

TPM="$(mktemp -d)/t"; QPID=""
cleanup() { kill ${QPID} 2>/dev/null || true; SWTPM_DIR="${TPM}" swtpm_stop 2>/dev/null || true; }
trap cleanup EXIT

disk="criu.qcow2"; vars="ovmf_vars_criu.fd"; CON="criu-console.log"
qemu-img convert -O qcow2 "${IMAGE}" "${disk}"; qemu-img resize "${disk}" +3G >/dev/null
cp "${OVMF_VARS_SRC}" "${vars}"
swtpm_start "${TPM}"

CRED_YAML="profile: worker
node_id: criu-node
criu: true"

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

echo "[criu] waiting for /v1/health (timeout 420s)"
deadline=$(( $(date +%s) + 420 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[criu] FAIL: /v1/health never came up"; tail -n 120 "${CON}"; exit 1
    fi
    sleep 3
done

echo "[criu] asserting the in-guest C/R cycle dumped+restored astromeshd (give it time)"
deadline=$(( $(date +%s) + 240 ))
until grep -aqE 'CRIU C/R GATE PASSED' "${CON}"; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[criu] FAIL: CRIU C/R cycle did not pass in the guest"
        echo "----- criu markers -----"; grep -aE 'criu\]' "${CON}" | tail -n 60
        exit 1
    fi
    if grep -aqE 'criu\] FAIL:' "${CON}"; then
        echo "[criu] FAIL: the in-guest orchestrator reported a failure"
        grep -aE 'criu\]' "${CON}" | tail -n 60
        exit 1
    fi
    sleep 3
done
echo "[criu] CRIU-DUMP/RESTORE + uptime-continuity + post-restore-run all OK in the guest"
echo "[criu] CRIU C/R GATE PASSED"
