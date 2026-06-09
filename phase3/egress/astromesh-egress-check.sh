#!/usr/bin/env bash
# Fase 3.5 egress self-check. Runs in-guest BEFORE astromeshd (which Requires= this unit), under the
# SAME IP filter (IPAddressDeny=any + the same IPAddressAllow lines). Asserts:
#   (1) POLICY-ACTIVE: astromeshd is configured with a non-empty IPAddressDeny (egress governed).
#   (2) POSITIVE-ALLOW: an allowlisted destination (loopback) is reachable through the filter — a
#       connect to 127.0.0.1:9 returns ECONNREFUSED (port closed) fast. A TIMEOUT/EPERM here would
#       mean the filter wrongly blocks loopback (fail-open against the runtime's own health/stub).
#   (3) POSITIVE-BLOCK: a routable, non-allowlisted destination is refused. systemd's cgroup-BPF
#       DROPS the packet SILENTLY, so a denied TCP connect TIMES OUT (verified empirically on
#       kernel 6.x; it does NOT return EPERM — though some kernels do, so we accept both). The
#       target 1.1.1.1:443 is reachable on the open internet, so ABSENT the filter this connects
#       fast: a CONNECTED/ECONNREFUSED result means egress LEAKED (filter not enforcing) and fails
#       the gate. That contrast (connects when allowed, times out when denied) makes the block proof
#       non-vacuous. NOTE: the gate guest must have outbound internet (via QEMU slirp NAT) for the
#       block side to be disambiguated from plain unreachability.
# Logs [egress] markers to console for the gate harness. Fail-closed: non-zero exit on any failure,
# and because astromeshd Requires= this unit, a failure here prevents astromeshd from starting.
set -uo pipefail
log() { echo "[egress] $*"; }
fail=0

# probe HOST PORT -> prints CONNECTED, TIMEOUT, or the errno code name (EPERM, ECONNREFUSED, ...).
# TIMEOUT is reported distinctly because a systemd cgroup-BPF drop manifests as a connect timeout
# (socket.timeout has errno None), which is the block signature on kernels that drop silently.
probe() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import socket, sys, errno
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect((host, port))
    print("CONNECTED")
except socket.timeout:
    print("TIMEOUT")
except OSError as e:
    print(errno.errorcode.get(e.errno, "E%d" % (e.errno or 0)))
finally:
    s.close()
PY
}

# 1. POLICY-ACTIVE: astromeshd carries a non-empty IPAddressDeny. This proves the policy is MERGED
#    into the unit config, not that the kernel installed the BPF filter — POSITIVE-BLOCK (step 3)
#    proves actual enforcement.
deny=$(systemctl show astromeshd.service -p IPAddressDeny --value 2>/dev/null || echo "")
if [ -n "${deny}" ]; then
    log "POLICY-ACTIVE OK (astromeshd IPAddressDeny=${deny})"
else
    log "FAIL: astromeshd has no IPAddressDeny — egress not governed"
    fail=1
fi

# 2. POSITIVE-ALLOW: loopback must be permitted — a fast ECONNREFUSED (closed port), not a
#    TIMEOUT/EPERM (which would mean the filter wrongly blocks loopback).
allow=$(probe 127.0.0.1 9)
log "loopback 127.0.0.1:9 -> ${allow}"
case "${allow}" in
    ECONNREFUSED|CONNECTED) log "POSITIVE-ALLOW OK (loopback permitted; ${allow})" ;;
    *)                      log "FAIL: loopback not permitted (${allow}) — expected ECONNREFUSED; allowlist not effective"; fail=1 ;;
esac

# 3. POSITIVE-BLOCK: a routable, non-allowlisted IP must be denied. The filter drops silently ->
#    TIMEOUT (some kernels return EPERM — accept both). CONNECTED/ECONNREFUSED means the SYN left the
#    box = egress LEAKED. A non-route error means we cannot disambiguate (guest lacks internet).
block=$(probe 1.1.1.1 443)
log "external 1.1.1.1:443 -> ${block}"
case "${block}" in
    TIMEOUT|ETIMEDOUT|EPERM|EACCES) log "POSITIVE-BLOCK OK (out-of-allowlist egress dropped/denied by the filter)" ;;
    CONNECTED|ECONNREFUSED)         log "FAIL: external egress to 1.1.1.1 was NOT blocked (${block}) — deny-by-default not enforcing (egress leaked)"; fail=1 ;;
    *)                              log "FAIL: external connect gave ${block} (no route?) — cannot confirm enforcement; the gate guest needs outbound internet"; fail=1 ;;
esac

if [ "${fail}" -ne 0 ]; then log "EGRESS FAILED"; exit 1; fi
log "EGRESS GATE OK"
