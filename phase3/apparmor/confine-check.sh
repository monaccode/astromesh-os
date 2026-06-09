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

# 2. No AppArmor denials for the astromeshd profile in normal op (checked BEFORE the
#    deliberate positive-block test below, which would add one).
denials=$(journalctl -k -b 2>/dev/null | grep -c 'apparmor="DENIED".*profile="astromeshd"' || true)
log "astromeshd DENIED count (normal op, this boot)=${denials}"
if [ "${denials}" = "0" ]; then
    log "NO-DENIALS OK"
else
    log "FAIL: ${denials} AppArmor denials for astromeshd in normal op"
    journalctl -k -b 2>/dev/null | grep 'apparmor="DENIED".*profile="astromeshd"' | head -5
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
