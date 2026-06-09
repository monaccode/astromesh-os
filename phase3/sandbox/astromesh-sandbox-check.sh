#!/usr/bin/env bash
# Fase 3.4 sandbox self-check (runs in-guest, after astromeshd is up). Asserts:
#   (1) astromeshd's MainPID is running under a loaded seccomp filter (Seccomp: 2),
#   (2) astromeshd has NoNewPrivs set (NoNewPrivs: 1),
#   (3) POSITIVE-BLOCK: creating a new namespace is actually denied under the sandbox
#       (this unit carries the same hardening, so an unshare here proves the profile blocks).
# Logs [sandbox] markers to console for the gate harness. Fail-closed: non-zero exit on any fail.
set -uo pipefail
log() { echo "[sandbox] $*"; }
fail=0

# 1+2. Inspect astromeshd's MainPID confinement via /proc/<pid>/status.
pid=$(systemctl show -p MainPID --value astromeshd 2>/dev/null || echo 0)
seccomp=$(awk '/^Seccomp:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo "")
nnp=$(awk '/^NoNewPrivs:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo "")
log "astromeshd MainPID=${pid} Seccomp=${seccomp:-?} NoNewPrivs=${nnp:-?}"
# Seccomp: 2 == SECCOMP_MODE_FILTER (a filter is loaded).
if [ "${seccomp}" = "2" ]; then log "SECCOMP OK"; else log "FAIL: astromeshd not seccomp-filtered (Seccomp=${seccomp:-none})"; fail=1; fi
if [ "${nnp}" = "1" ]; then log "NO-NEW-PRIVS OK"; else log "FAIL: astromeshd without NoNewPrivs (NoNewPrivs=${nnp:-none})"; fail=1; fi

# 3. POSITIVE-BLOCK: under RestrictNamespaces (this unit carries it), creating a new user
#    namespace must be denied. unshare(2) is blocked by the seccomp namespace restriction and
#    surfaces as EPERM ("Operation not permitted"). A success here means the sandbox is NOT
#    enforcing namespace restriction.
err=$(unshare --user --map-root-user true 2>&1)
rc=$?
if [ "${rc}" -eq 0 ]; then
    log "FAIL: unshare(new userns) SUCCEEDED under the sandbox (RestrictNamespaces not enforcing)"
    fail=1
elif printf '%s' "${err}" | grep -qiE 'Operation not permitted|EPERM|permission denied'; then
    log "POSITIVE-BLOCK OK (new-namespace creation denied by the sandbox)"
else
    log "FAIL: unshare failed but not via permission-denied. stderr: ${err}"
    fail=1
fi

if [ "${fail}" -ne 0 ]; then log "SANDBOX FAILED"; exit 1; fi
log "SANDBOX GATE OK"
