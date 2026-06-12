#!/usr/bin/env bash
# §12.2a sched_ext loader wrapper. Guarded: no-op unless the active runtime.yaml has
# spec.sched_ext.enabled: true. On a schedext boot it auto-detects an scx scheduler binary (from the
# baked `scx` package) and execs it in the FOREGROUND — while this process lives, the BPF scheduler is
# attached; if it dies, the kernel's sched_ext watchdog reverts to CFS. Runs privileged (loading a
# struct_ops BPF scheduler needs full caps), so this unit carries NO hardening drop-in.
set -uo pipefail
log() { echo "[schedext] $*"; }
RT=/var/lib/astromesh/runtime.yaml
PY=/opt/astromesh/venv/bin/python3

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

# Auto-detect an scx scheduler binary (the Debian `scx` package may ship any of these).
SCHED=""
for cand in scx_simple scx_bpfland scx_rusty scx_lavd; do
    if command -v "${cand}" >/dev/null 2>&1; then SCHED="${cand}"; break; fi
done
[ -n "${SCHED}" ] || { log "FAIL: no scx scheduler binary found on PATH (scx package not baked?)"; exit 1; }

log "loading sched_ext scheduler: ${SCHED}"
exec "${SCHED}"
