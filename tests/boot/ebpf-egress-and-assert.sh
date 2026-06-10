#!/usr/bin/env bash
# Fase 4.4 gate: boot ONE VM with an `ebpf_egress` machine-config. Assert the eBPF program attaches to
# astromeshd's cgroup, then run an agent (stub provider) and assert the per-flow map counted the
# loopback provider call (dst 127.0.0.1:8081). Proves causal per-flow egress accounting.
set -euo pipefail
IMAGE="${1:?usage: ebpf-egress-and-assert.sh <v1-raw-image>}"
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
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[ebpf] FAIL: OVMF not found"; exit 1; }

TPM="$(mktemp -d)/t"; QPID=""
cleanup() { kill ${QPID} 2>/dev/null || true; SWTPM_DIR="${TPM}" swtpm_stop 2>/dev/null || true; }
trap cleanup EXIT

disk="ebpf.qcow2"; vars="ovmf_vars_ebpf.fd"; CON="ebpf-console.log"
qemu-img convert -O qcow2 "${IMAGE}" "${disk}"; qemu-img resize "${disk}" +3G >/dev/null
cp "${OVMF_VARS_SRC}" "${vars}"
swtpm_start "${TPM}"

CRED_YAML="profile: worker
node_id: ebpf-node
ebpf_egress: true"

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

echo "[ebpf] waiting for /v1/health (timeout 420s)"
deadline=$(( $(date +%s) + 420 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[ebpf] FAIL: /v1/health never came up"; tail -n 120 "${CON}"; exit 1
    fi
    sleep 3
done

grep -aq "ebpf\] EBPF-EGRESS-ATTACHED OK" "${CON}" || {
    echo "[ebpf] FAIL: program not attached"; grep -aE 'ebpf' "${CON}" | tail -n 30; exit 1; }
echo "[ebpf] EBPF-EGRESS-ATTACHED OK"

echo "[ebpf] triggering agent runs (stub provider) to generate egress"
for i in 1 2 3; do
    curl -fsS -X POST "http://localhost:${PORT}/v1/agents/phase0-smoke/run" \
        -H 'Content-Type: application/json' \
        -d '{"query":"ebpf gate ping","session_id":"ebpf-gate"}' >/dev/null 2>&1 || true
    sleep 1
done

# The egress-acct-dump.timer prints [ebpf-flow] markers to console every 10s. Poll for the stub flow.
echo "[ebpf] asserting the flow map counted the stub call (dst port 8081)"
deadline=$(( $(date +%s) + 90 ))
until grep -aqE '\[ebpf-flow\].*dport=8081 .*bytes=[1-9]' "${CON}"; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[ebpf] FAIL: no counted flow to dport=8081 in the map"
        grep -aE 'ebpf-flow|ebpf\]' "${CON}" | tail -n 40; exit 1
    fi
    sleep 3
done
echo "[ebpf] CAUSAL-EGRESS OK (per-flow egress to the stub counted on astromeshd's cgroup)"
echo "[ebpf] EBPF EGRESS GATE PASSED"
