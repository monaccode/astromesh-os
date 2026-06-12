#!/usr/bin/env bash
# §12.7 CRIU checkpoint/restore self-check/orchestrator. Runs PRIVILEGED (no hardening drop-in), After=
# astromeshd. Guarded: no-op unless the active runtime.yaml has spec.criu.enabled: true. On a criu boot:
#   1. criu dump --tree <pid> --leave-running   (snapshot WITHOUT killing — systemd undisturbed)
#   2. systemctl stop astromeshd                 (clean stop frees :8000 and the PID; no Restart race)
#   3. criu restore -d                           (bring the snapshot back, detached, re-binding :8000)
# Then asserts UPTIME CONTINUITY (/v1/system/status.uptime_seconds does NOT reset — a plain restart would
# give ~0; CRIU keeps _start_time) and FUNCTIONAL CONTINUITY (a post-restore agent run answers). Markers
# to console for the gate harness. The CRIU flags are an iteration item (see spec §7).
set -uo pipefail
log() { echo "[criu] $*"; }
RT=/var/lib/astromesh/runtime.yaml
IMG=/var/lib/astromesh/criu
PORT=8000
BASE="http://127.0.0.1:${PORT}"
PY=/opt/astromesh/venv/bin/python3

# Guard: only run on criu boots (spec.criu.enabled: true in the active runtime.yaml).
en=$("${PY}" - "${RT}" <<'PYEOF' 2>/dev/null || true
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    d = {}
print(str(((d.get("spec") or {}).get("criu") or {}).get("enabled", "")).strip().lower())
PYEOF
)
if [ "${en}" != "true" ]; then log "no es boot criu; skipping"; exit 0; fi

uptime_of() {
    curl -fsS "${BASE}/v1/system/status" 2>/dev/null \
        | "${PY}" -c 'import sys,json; print(json.load(sys.stdin).get("uptime_seconds",-1))' 2>/dev/null \
        || echo "-1"
}

log "waiting for astromeshd /v1/health (timeout ~240s)"
for _ in $(seq 1 120); do curl -fsS "${BASE}/v1/health" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "${BASE}/v1/health" >/dev/null 2>&1 || { log "FAIL: astromeshd /v1/health never came up"; exit 1; }

U1=$(uptime_of); log "pre-checkpoint uptime=${U1}"
# warm: an agent run serves PRE-checkpoint (stub provider)
curl -fsS -X POST "${BASE}/v1/agents/phase0-smoke/run" -H 'Content-Type: application/json' \
    -d '{"query":"criu pre","session_id":"criu-1"}' >/dev/null 2>&1 || true

PID=$(systemctl show -p MainPID --value astromeshd.service 2>/dev/null || echo "")
[ -n "${PID}" ] && [ "${PID}" != "0" ] || { log "FAIL: no astromeshd MainPID"; exit 1; }
log "astromeshd MainPID=${PID}"

install -d -m 0700 "${IMG}"; rm -f "${IMG}"/*.img "${IMG}"/*.log 2>/dev/null || true

# 1. DUMP, leaving the process running. Flags are an iteration item (spec §7): external unix sockets
#    (journald stdout, sd_notify), TCP listen socket, file locks. Start here; refine on first run.
if criu dump --tree "${PID}" --leave-running --images-dir "${IMG}" \
        --tcp-established --file-locks --ext-unix-sk --link-remap 2>"${IMG}/dump.log"; then
    log "CRIU-DUMP OK"
else
    log "FAIL: criu dump failed"; tail -n 60 "${IMG}/dump.log" 2>/dev/null || true; exit 1
fi

# 2. Clean stop (frees :8000 and the PID; an intentional stop is NOT a failure, so systemd won't restart).
log "stopping astromeshd.service (clean) before restore"
systemctl stop astromeshd.service 2>/dev/null || true
for _ in $(seq 1 30); do curl -fsS "${BASE}/v1/health" >/dev/null 2>&1 || break; sleep 1; done

# 3. RESTORE detached.
if criu restore -d --images-dir "${IMG}" \
        --tcp-established --file-locks --ext-unix-sk --link-remap 2>"${IMG}/restore.log"; then
    log "CRIU-RESTORE OK"
else
    log "FAIL: criu restore failed"; tail -n 60 "${IMG}/restore.log" 2>/dev/null || true; exit 1
fi

log "waiting for restored astromeshd on :${PORT}"
for _ in $(seq 1 60); do curl -fsS "${BASE}/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "${BASE}/v1/health" >/dev/null 2>&1 \
    || { log "FAIL: restored astromeshd not serving /v1/health"; tail -n 60 "${IMG}/restore.log" 2>/dev/null || true; exit 1; }

U2=$(uptime_of); log "post-restore uptime=${U2}"

# FUNCTIONAL continuity: a post-restore agent run must answer over the restored :8000 socket.
if curl -fsS -X POST "${BASE}/v1/agents/phase0-smoke/run" -H 'Content-Type: application/json' \
        -d '{"query":"criu post","session_id":"criu-2"}' >/dev/null 2>&1; then
    log "POST-RESTORE-RUN OK"
else
    log "FAIL: post-restore agent run did not answer"; exit 1
fi

# UPTIME continuity: U2 must be >= U1 (a plain restart resets _start_time -> uptime ~0).
cont=$("${PY}" -c "import sys; print('yes' if float('${U2}')>=float('${U1}') and float('${U1}')>=0 else 'no')" 2>/dev/null || echo "no")
if [ "${cont}" = "yes" ]; then
    log "UPTIME-CONTINUOUS OK (U1=${U1} -> U2=${U2}, not reset)"
else
    log "FAIL: uptime reset (U1=${U1} -> U2=${U2}) — restored process is not the checkpointed one"; exit 1
fi

log "CRIU C/R GATE PASSED"
