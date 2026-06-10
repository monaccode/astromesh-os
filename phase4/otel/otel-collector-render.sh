#!/usr/bin/env bash
# Fase 4.3: render the otelcol config to writable /run (the baked config lives on read-only verity) and
# exec the collector. Guarded: no-op unless the active runtime.yaml enabled OTLP export
# (observability.otlp.enabled: true), so non-otel boots (Fase 0/2/3/4.1/4.2) are unaffected.
set -uo pipefail
log() { echo "[otel] $*"; }
RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'otlp:' "${RT}" 2>/dev/null \
    || { log "not an otel boot; skipping collector"; exit 0; }

SRC_CFG=/usr/lib/astromesh-os/otel/otelcol.yaml
RUN_CFG=/run/otel/otelcol.yaml
install -d -m 0755 /run/otel
install -m 0644 "${SRC_CFG}" "${RUN_CFG}"
log "OTEL-COLLECTOR OK (config=${RUN_CFG} listen=127.0.0.1:4317)"
exec /usr/bin/otelcol --config "${RUN_CFG}"
