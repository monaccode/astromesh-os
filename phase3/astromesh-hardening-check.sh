#!/usr/bin/env bash
# Fase 3.1 hardening self-check: assert the no-shell posture at boot and report the
# break-glass credential state. Fail-closed: non-zero exit if the posture is violated.
# Mirrors phase2/immutability-check.sh; output goes to journal+console so the gate
# harness can grep the marker.
set -uo pipefail
fail=0
log() { echo "[hardening] $*"; }

# 1. No interactive login: the getty templates must be masked (masking a template masks
#    all instances). A unit that does not exist at all is also fine (no login path).
for u in serial-getty@.service getty@.service; do
    # `systemctl is-enabled` prints "masked" (or nothing, for a non-existent unit) to stdout
    # and exits NON-ZERO for both. So DON'T append a fallback with `|| echo ...` — that would
    # concatenate onto the real "masked" output and corrupt the match. Capture stdout only;
    # empty == no such unit == also no login path == OK.
    state=$(systemctl is-enabled "$u" 2>/dev/null || true)
    case "$state" in
        masked|"") ;;
        *) log "FAIL: ${u} is '${state}', expected masked"; fail=1 ;;
    esac
done

# 2. No SSH server installed (anti-regression: it is never in Packages=).
if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
    log "FAIL: openssh-server is installed"; fail=1
fi

# 3. Break-glass credential state: root has a usable hash (configured) vs locked (disabled).
rh=$(getent shadow root | cut -d: -f2)
case "${rh}" in
    ''|'!'|'*'|'!!'|'!*') log "BREAK-GLASS=disabled (root locked)" ;;
    *)                    log "BREAK-GLASS=configured" ;;
esac

if [ "${fail}" -ne 0 ]; then
    log "NO-SHELL FAILED"
    exit 1
fi
log "NO-SHELL OK"
