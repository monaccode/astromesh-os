#!/usr/bin/env bash
# §12.2a sched_ext self-check. Guarded (no-op unless spec.sched_ext.enabled). Runs After= the loader.
# Asserts: (1) the kernel supports sched_ext (/sys/kernel/sched_ext exists), (2) a custom scheduler is
# ACTIVE (state == enabled + a non-empty ops name), (3) astromeshd is functional under it (/v1/health
# 200). Markers [schedext] to console for the gate harness.
set -uo pipefail
log() { echo "[schedext] $*"; }
RT=/var/lib/astromesh/runtime.yaml
PY=/opt/astromesh/venv/bin/python3
fail=0

en=$("${PY}" - "${RT}" <<'PYEOF' 2>/dev/null || true
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    d = {}
print(str(((d.get("spec") or {}).get("sched_ext") or {}).get("enabled", "")).strip().lower())
PYEOF
)
if [ "${en}" != "true" ]; then log "no es boot schedext; skipping"; exit 0; fi

# 1. SUPPORTED: the kernel has CONFIG_SCHED_CLASS_EXT (the sysfs dir exists).
if [ -d /sys/kernel/sched_ext ]; then
    log "SCHEDEXT-SUPPORTED OK (/sys/kernel/sched_ext present)"
else
    log "FAIL: /sys/kernel/sched_ext missing — kernel lacks CONFIG_SCHED_CLASS_EXT"; log "SCHEDEXT FAILED"; exit 1
fi

# 2. ACTIVE: a custom scheduler is loaded. Give the loader a moment to attach.
state=""; ops=""
for _ in $(seq 1 30); do
    state=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "")
    ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo "")
    [ "${state}" = "enabled" ] && [ -n "${ops}" ] && break
    sleep 1
done
log "sched_ext state=${state:-?} ops=${ops:-?}"
if [ "${state}" = "enabled" ] && [ -n "${ops}" ]; then
    log "SCHEDEXT-ACTIVE OK (custom scheduler '${ops}' is the active CPU scheduler)"
else
    log "FAIL: no custom sched_ext scheduler active (state=${state:-none} ops=${ops:-none})"; fail=1
fi

# 3. FUNCTIONAL: astromeshd still serves under the custom scheduler.
ok=0
for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:8000/v1/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
done
if [ "${ok}" -eq 1 ]; then
    log "RUNTIME-FUNCTIONAL OK (astromeshd /v1/health 200 under the custom scheduler)"
else
    log "FAIL: astromeshd /v1/health did not come up under the custom scheduler"; fail=1
fi

if [ "${fail}" -ne 0 ]; then log "SCHEDEXT FAILED"; exit 1; fi
log "SCHEDEXT GATE OK"
