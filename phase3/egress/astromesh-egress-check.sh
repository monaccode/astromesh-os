#!/usr/bin/env bash
# Fase 3.5 egress self-check. Runs in-guest BEFORE astromeshd (which Requires= this unit), under the
# SAME IP filter (IPAddressDeny=any + the same IPAddressAllow lines). Asserts:
#   (1) POLICY-ACTIVE: astromeshd is configured with a non-empty IPAddressDeny (egress governed).
#   (2) POSITIVE-ALLOW: an allowlisted destination (loopback) is reachable through the filter — a
#       connect to 127.0.0.1:9 fails with ECONNREFUSED (port closed), NOT EPERM. EPERM here would
#       mean the filter wrongly blocks loopback (fail-open against the runtime's own health/stub).
#   (3) POSITIVE-BLOCK: a non-allowlisted destination is refused — a connect to 192.0.2.1:80
#       (TEST-NET-1, RFC5737, outside 10.0.2.0/24) fails with EPERM/EACCES. systemd's cgroup-BPF
#       drop returns EPERM locally, so this is deterministic and needs no internet.
# Logs [egress] markers to console for the gate harness. Fail-closed: non-zero exit on any failure,
# and because astromeshd Requires= this unit, a failure here prevents astromeshd from starting.
set -uo pipefail
log() { echo "[egress] $*"; }
fail=0

# probe HOST PORT -> prints CONNECTED or the errno code name (e.g. EPERM, ECONNREFUSED, ETIMEDOUT).
probe() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import socket, sys, errno
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect((host, port))
    print("CONNECTED")
except OSError as e:
    print(errno.errorcode.get(e.errno, "E%d" % (e.errno or 0)))
finally:
    s.close()
PY
}

# 1. POLICY-ACTIVE: astromeshd carries a non-empty IPAddressDeny.
deny=$(systemctl show astromeshd.service -p IPAddressDeny --value 2>/dev/null || echo "")
if [ -n "${deny}" ]; then
    log "POLICY-ACTIVE OK (astromeshd IPAddressDeny=${deny})"
else
    log "FAIL: astromeshd has no IPAddressDeny — egress not governed"
    fail=1
fi

# 2. POSITIVE-ALLOW: loopback must be permitted (errno must NOT be EPERM/EACCES).
allow=$(probe 127.0.0.1 9)
log "loopback 127.0.0.1:9 -> ${allow}"
case "${allow}" in
    EPERM|EACCES) log "FAIL: loopback blocked by the filter (${allow}) — allowlist not effective"; fail=1 ;;
    *)            log "POSITIVE-ALLOW OK (loopback permitted; ${allow})" ;;
esac

# 3. POSITIVE-BLOCK: a non-allowlisted external IP must be denied (errno EPERM/EACCES).
block=$(probe 192.0.2.1 80)
log "external 192.0.2.1:80 -> ${block}"
case "${block}" in
    EPERM|EACCES) log "POSITIVE-BLOCK OK (out-of-allowlist egress denied by the filter)" ;;
    CONNECTED|ECONNREFUSED) log "FAIL: external egress to 192.0.2.1 was NOT blocked (${block}) — deny-by-default not enforcing"; fail=1 ;;
    *)            log "FAIL: external connect gave ${block}, expected EPERM (filter denial) — cannot confirm enforcement"; fail=1 ;;
esac

if [ "${fail}" -ne 0 ]; then log "EGRESS FAILED"; exit 1; fi
log "EGRESS GATE OK"
