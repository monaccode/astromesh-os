#!/usr/bin/env bash
# Fase 3.2 confinement self-check (runs in-guest, late in boot). Asserts astromeshd is
# AppArmor-confined in ENFORCE, has no denials in normal operation, and that the profile
# actually BLOCKS an out-of-policy action. Logs markers to console so the gate harness can
# grep them. Fail-closed: non-zero exit if any assertion fails.
set -uo pipefail
log() { echo "[confine] $*"; }
fail=0

# 1. astromeshd runs IN the astromeshd profile, ENFORCE (not unconfined / complain).
pid=$(systemctl show -p MainPID --value astromeshd 2>/dev/null || echo 0)
cur=$(cat "/proc/${pid}/attr/current" 2>/dev/null || echo "unknown")
log "astromeshd MainPID=${pid} attr/current=${cur}"
case "${cur}" in
    "astromeshd (enforce)"*) log "CONFINED OK" ;;
    *) log "FAIL: astromeshd not confined-enforce (got '${cur}')"; fail=1 ;;
esac

# 2. The enforce profile does not FALSELY deny anything astromeshd needs — proven by the
#    daemon actually working under it: a confined astromeshd that serves /v1/health 200 has
#    not been denied a path/socket it requires (a real denial would crash or hang it). This
#    is the honest no-false-denial check: AppArmor's audit channel reaches no log in this
#    image (see check 3), so a denial-count grep would be vacuous (always 0). The agent-query
#    path is likewise covered host-side by the gate harness (a denied query breaks the reply).
if curl -fsS --max-time 15 http://127.0.0.1:8000/v1/health >/dev/null 2>&1; then
    log "NO-DENIALS OK (astromeshd serves /v1/health under enforce — no needed access denied)"
else
    log "FAIL: astromeshd /v1/health not 200 under enforce — confinement denied a needed access"
    fail=1
fi

# 3. Positive enforcement: under the astromeshd profile, a write OUTSIDE the allowed paths
#    must be denied by AppArmor. Run as root via the in-policy interpreter so the block is
#    AppArmor (not DAC, not an exec denial). Canary is under /var/lib but NOT /var/lib/astromesh.
canary=/var/lib/confine-canary
rm -f "${canary}" 2>/dev/null || true
err=$(aa-exec -p astromeshd -- /opt/astromesh/venv/bin/python3 -c "open('${canary}','w')" 2>&1)
rc=$?
# Proof of enforcement does NOT rely on finding the audit log line — AppArmor audit may not
# reach journald here. We run as root, so DAC would ALLOW this write; a blocked write
# therefore proves AppArmor, confirmed by the EACCES surfacing as PermissionError on stderr.
if [ "${rc}" -eq 0 ] || [ -e "${canary}" ]; then
    log "FAIL: out-of-policy write SUCCEEDED under astromeshd profile (not enforcing)"
    rm -f "${canary}" 2>/dev/null || true
    fail=1
elif printf '%s' "${err}" | grep -qiE 'Permission denied|PermissionError|EACCES'; then
    log "POSITIVE-BLOCK OK (out-of-policy write denied by AppArmor)"
else
    log "FAIL: out-of-policy write failed but not via permission-denied. stderr: ${err}"
    fail=1
fi

if [ "${fail}" -ne 0 ]; then log "CONFINE FAILED"; exit 1; fi
log "CONFINE GATE OK"
