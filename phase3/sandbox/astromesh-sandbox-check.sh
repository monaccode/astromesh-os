#!/usr/bin/env bash
# Fase 3.4 sandbox self-check. Runs in-guest BEFORE astromeshd (which Requires= this unit), under
# the SAME hardening directives. Asserts:
#   (1) this process runs under a loaded seccomp filter (Seccomp: 2) — a faithful proxy for
#       astromeshd, which carries identical directives,
#   (2) NoNewPrivs is set (NoNewPrivs: 1),
#   (3) POSITIVE-BLOCK: a socket in a family OUTSIDE RestrictAddressFamilies (AF_NETLINK) is
#       denied. AF_NETLINK is creatable by unprivileged users WITHOUT a sandbox, so a denial here
#       is attributable to the sandbox (RestrictAddressFamilies), not to ambient kernel policy
#       (unlike, e.g., unprivileged-userns sysctls).
# Logs [sandbox] markers to console for the gate harness. Fail-closed: non-zero exit on any fail,
# and because astromeshd Requires= this unit, a failure here prevents astromeshd from starting.
set -euo pipefail
log() { echo "[sandbox] $*"; }
fail=0

# 1+2. Inspect OUR OWN confinement (we carry the same directives as astromeshd).
seccomp=$(awk '/^Seccomp:/{print $2}' /proc/self/status 2>/dev/null || echo "")
nnp=$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status 2>/dev/null || echo "")
log "self Seccomp=${seccomp:-?} NoNewPrivs=${nnp:-?}"
# Seccomp: 2 == SECCOMP_MODE_FILTER (a filter is loaded).
if [ "${seccomp}" = "2" ]; then log "SECCOMP OK"; else log "FAIL: not seccomp-filtered (Seccomp=${seccomp:-none})"; fail=1; fi
if [ "${nnp}" = "1" ]; then log "NO-NEW-PRIVS OK"; else log "FAIL: NoNewPrivs not set (NoNewPrivs=${nnp:-none})"; fail=1; fi

# 3. POSITIVE-BLOCK: creating an AF_NETLINK socket must be denied by RestrictAddressFamilies
#    (allowed set is AF_INET/AF_INET6/AF_UNIX). Surfaces as EAFNOSUPPORT ("Address family not
#    supported"). `|| rc=$?` keeps the expected failure from tripping `set -e`.
rc=0
err=$(/usr/bin/python3 -c 'import socket; socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0)' 2>&1) || rc=$?
if [ "${rc}" -eq 0 ]; then
    log "FAIL: AF_NETLINK socket SUCCEEDED under the sandbox (RestrictAddressFamilies not enforcing)"
    fail=1
elif printf '%s' "${err}" | grep -qiE 'Address family not supported|EAFNOSUPPORT|Operation not permitted|permission denied'; then
    log "POSITIVE-BLOCK OK (out-of-policy socket family denied by RestrictAddressFamilies)"
else
    log "FAIL: AF_NETLINK socket failed but not via address-family/permission denial. stderr: ${err}"
    fail=1
fi

if [ "${fail}" -ne 0 ]; then log "SANDBOX FAILED"; exit 1; fi
log "SANDBOX GATE OK"
