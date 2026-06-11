#!/usr/bin/env bash
# Fase 4.3b gate: boot ONE VM with an `otel` machine-config (flips observability.otlp.enabled). Assert
# the baked otelcol sidecar is up and that a real agent run's METRICS are EXPORTED to it — the
# collector's debug exporter logs received metrics to the console. Positive: `astromesh.agent.runs`
# (always emitted by any run) reaches the collector; `astromesh.agent.tokens` is asserted too (the
# stub emits usage). Cost is best-effort (the stub may report cost=0), so it is logged, not required.
set -euo pipefail
IMAGE="${1:?usage: otel-metrics-and-assert.sh <v1-raw-image>}"
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

disk="otelm.qcow2"; vars="ovmf_vars_otelm.fd"; CON="otel-metrics-console.log"
qemu-img convert -O qcow2 "${IMAGE}" "${disk}"; qemu-img resize "${disk}" +3G >/dev/null
cp "${OVMF_VARS_SRC}" "${vars}"
swtpm_start "${TPM}"

CRED_YAML="profile: worker
node_id: otel-metrics-node
otel: true"

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
echo "[otel] OTEL-COLLECTOR OK (sidecar listening on 127.0.0.1:4317)"

echo "[otel] triggering agent runs (stub provider) to generate engine metrics"
for i in 1 2 3; do
    curl -fsS -X POST "http://localhost:${PORT}/v1/agents/phase0-smoke/run" \
        -H 'Content-Type: application/json' \
        -d '{"query":"otel metrics ping","session_id":"otel-metrics"}' >/dev/null 2>&1 || true
    sleep 1
done

# Assert on the COLLECTOR's debug-exporter metric dump. The debug exporter prints each metric as
# `Name: astromesh.agent.runs` with attributes like `agent: Str(phase0-smoke)` (same format the 4.4c
# gate matches for astromesh.agent.egress.bytes). Require runs (any run emits it) + tokens (the stub
# reports usage). Cost is best-effort.
echo "[otel] asserting engine metrics reached the collector (astromesh.agent.runs + .tokens)"
deadline=$(( $(date +%s) + 120 ))
until grep -aqE 'astromesh\.agent\.runs' "${CON}" \
   && grep -aqE 'agent: Str\(phase0-smoke\)' "${CON}" \
   && grep -aqE 'astromesh\.agent\.tokens' "${CON}"; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[otel] FAIL: engine metrics not seen in the collector dump"
        echo "----- collector metric markers -----"; grep -aE 'astromesh\.(agent|llm|tool)|Name:|agent:|Value:' "${CON}" | tail -n 60
        echo "----- node export markers -----"; grep -aE 'agent-egress metric export enabled|OTLP trace export enabled|agent metrics unavailable' "${CON}" | tail -n 10
        exit 1
    fi
    sleep 3
done
echo "[otel] ENGINE-METRICS-EXPORTED OK (astromesh.agent.runs + .tokens{agent=phase0-smoke} reached the collector)"

if grep -aqE 'astromesh\.agent\.cost' "${CON}"; then
    echo "[otel] (bonus) astromesh.agent.cost also exported"
else
    echo "[otel] note: astromesh.agent.cost not present (stub reported cost=0) — not required by the gate"
fi
echo "[otel] OTEL METRICS GATE PASSED"
