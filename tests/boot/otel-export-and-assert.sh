#!/usr/bin/env bash
# Fase 4.3 gate: boot ONE VM with an `otel` machine-config (flips observability.otlp.enabled). Assert
# the baked otelcol sidecar is up and that a real agent run's spans are EXPORTED to it — the collector's
# debug exporter logs received spans to the console. Positive: an `agent.run` span reaches the collector.
set -euo pipefail
IMAGE="${1:?usage: otel-export-and-assert.sh <v1-raw-image>}"
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

disk="otel.qcow2"; vars="ovmf_vars_otel.fd"; CON="otel-console.log"
qemu-img convert -O qcow2 "${IMAGE}" "${disk}"; qemu-img resize "${disk}" +3G >/dev/null
cp "${OVMF_VARS_SRC}" "${vars}"
swtpm_start "${TPM}"

CRED_YAML="profile: worker
node_id: otel-node
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

echo "[otel] triggering an agent run (stub provider) to emit spans"
curl -fsS -X POST "http://localhost:${PORT}/v1/agents/phase0-smoke/run" \
    -H 'Content-Type: application/json' \
    -d '{"query":"otel gate ping","session_id":"otel-gate"}' >/dev/null 2>&1 || true

# Assert on the COLLECTOR's debug-exporter dump (`Span #` and a `Name ... : agent.run` field), NOT on
# astromeshd's own "agent.run ... finished" log line — only the otelcol debug exporter emits `Span #` /
# `ResourceSpans`. This also makes the loop WAIT for the node's BatchSpanProcessor to flush (~5s) and the
# collector to print, instead of matching a log line instantly.
echo "[otel] asserting the collector's debug exporter dumped an agent.run span (give the batch ~flush)"
deadline=$(( $(date +%s) + 120 ))
until grep -aqE 'Span #[0-9]' "${CON}" && grep -aqE 'Name +: +agent\.run' "${CON}"; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[otel] FAIL: collector never dumped an agent.run span (export did not reach the collector)"
        echo "----- collector (otel) output -----"; grep -aE 'otel-collector-render|ResourceSpans|ScopeSpans|Span #|Name +:|TracesExporter|otlp|export' "${CON}" | tail -n 50
        echo "----- node export markers -----"; grep -aE 'OTLP trace export enabled|OTLP export setup failed|agent\.run' "${CON}" | tail -n 10
        exit 1
    fi
    sleep 3
done
echo "[otel] SPAN-EXPORTED OK (the collector's debug exporter dumped the agent.run span over OTLP)"
echo "[otel] OTEL EXPORT GATE PASSED"
