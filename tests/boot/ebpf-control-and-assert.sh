#!/usr/bin/env bash
# Fase 4.4e gate: boot ONE VM with an `ebpf_egress + otel + ebpf_egress_quota:500` machine-config. The
# Rust daemon (libbpf-rs) loads+attaches the eBPF egress program, observes the phase0-smoke stub flow
# (127.0.0.1:8081) exceed the quota, and writes it to the eBPF `deny` map — so the kernel DROPS further
# egress to the stub. We assert BOTH: the daemon's DECISION ([ctl] DENY 127.0.0.1:8081) and the
# ENFORCEMENT (a post-deny agent run can no longer reach the provider). Control, not telemetry.
set -euo pipefail
IMAGE="${1:?usage: ebpf-control-and-assert.sh <v1-raw-image>}"
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
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[otel] FAIL: OVMF not found"; exit 1; }

TPM="$(mktemp -d)/t"; QPID=""
cleanup() { kill ${QPID} 2>/dev/null || true; SWTPM_DIR="${TPM}" swtpm_stop 2>/dev/null || true; }
trap cleanup EXIT

disk="ebpf-control.qcow2"; vars="ovmf_vars_ebpf_control.fd"; CON="ebpf-control-console.log"
qemu-img convert -O qcow2 "${IMAGE}" "${disk}"; qemu-img resize "${disk}" +3G >/dev/null
cp "${OVMF_VARS_SRC}" "${vars}"
swtpm_start "${TPM}"

CRED_YAML="profile: worker
node_id: ebpf-control-node
ebpf_egress: true
otel: true
ebpf_egress_quota: 500"

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

echo "[otel] waiting for /v1/health (timeout 420s)"
deadline=$(( $(date +%s) + 420 ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[otel] FAIL: /v1/health never came up"; tail -n 120 "${CON}"; exit 1
    fi
    sleep 3
done

grep -aq "otel\] OTEL-COLLECTOR OK" "${CON}" || { echo "[otel] FAIL: collector not up"; grep -aE 'otel\]' "${CON}" | tail; exit 1; }
grep -aq "ASTROMESH-EBPF ATTACHED OK" "${CON}" || { echo "[otel] FAIL: Rust eBPF daemon not attached"; grep -aE 'astromesh-ebpf|ASTROMESH-EBPF|otel\]' "${CON}" | tail -n 20; exit 1; }
echo "[otel] OTEL-COLLECTOR OK + ASTROMESH-EBPF ATTACHED OK"

echo "[otel] generating egress (stub provider) to exceed the 500-byte quota"
for i in $(seq 1 8); do
    curl -fsS -X POST "http://localhost:${PORT}/v1/agents/phase0-smoke/run" \
        -H 'Content-Type: application/json' \
        -d '{"query":"control ping","session_id":"ctl"}' >/dev/null 2>&1 || true
    sleep 1
done

# 1) DECISION: the daemon's 10s loop observes the stub flow > quota and writes it to the deny map.
echo "[otel] asserting the daemon DECIDED to deny the stub flow (quota exceeded)"
deadline=$(( $(date +%s) + 150 ))
until grep -aqE '\[ctl\] DENY 127\.0\.0\.1:8081' "${CON}"; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[otel] FAIL: daemon never denied the stub flow"
        echo "----- ctl markers -----"; grep -aE 'ctl\]|ASTROMESH-EBPF' "${CON}" | tail -n 30
        exit 1
    fi
    sleep 3
done
echo "[ctl] DENY DECISION OK"; grep -aE '\[ctl\] DENY' "${CON}" | tail -n 3

# 2) ENFORCEMENT: with 127.0.0.1:8081 in the deny map, the kernel drops astromeshd's egress to the stub,
#    so a fresh agent run can no longer reach the provider. The dropped egress surfaces as a provider
#    error / empty answer / timeout in the run response (or the request itself errors/times out).
echo "[otel] asserting ENFORCEMENT: a post-deny agent run cannot reach the provider"
sleep 6
resp=$(curl -fsS -m 30 -X POST "http://localhost:${PORT}/v1/agents/phase0-smoke/run" \
    -H 'Content-Type: application/json' -d '{"query":"after deny","session_id":"ctl2"}' 2>&1 || echo "REQUEST_FAILED")
echo "[otel] post-deny run response: ${resp:0:240}"
if echo "${resp}" | grep -aqiE 'REQUEST_FAILED|error|provider|unreachable|timed out|timeout|connection|refused|503|502|500|"answer": ?""|"answer":""'; then
    echo "[ctl] EGRESS-DENY ENFORCED OK (post-deny provider call dropped)"
else
    echo "[otel] FAIL: post-deny agent run still reached the provider (enforcement not effective)"
    echo "${resp:0:600}"
    echo "----- ctl markers -----"; grep -aE 'ctl\]' "${CON}" | tail -n 10
    exit 1
fi
echo "[otel] EBPF CONTROL GATE PASSED"
