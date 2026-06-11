#!/usr/bin/env bash
# §12.3 memory governance self-check. Runs BEFORE astromeshd (which Requires= this unit via
# 50-memory.conf). Fail-closed: if memory governance isn't configured OR the kernel doesn't enforce
# cgroup memory limits, this exits non-zero -> astromeshd's Requires= fails -> astromeshd does not start.
# Asserts: (1) astromeshd.service has MemoryAccounting=yes + a finite MemoryMax + OOMPolicy=kill;
# (2) POSITIVE-OOM: a 512M hog in a transient MemoryMax=64M scope is cgroup-OOM-contained (cannot
# complete) while this check and the host survive. Markers [memory] to console for the gate harness.
set -uo pipefail
log() { echo "[memory] $*"; }
fail=0

ACC=$(systemctl show astromeshd.service -p MemoryAccounting --value 2>/dev/null || echo "")
MAX=$(systemctl show astromeshd.service -p MemoryMax --value 2>/dev/null || echo "")
OOM=$(systemctl show astromeshd.service -p OOMPolicy --value 2>/dev/null || echo "")
log "astromeshd MemoryAccounting=${ACC:-?} MemoryMax=${MAX:-?} OOMPolicy=${OOM:-?}"

if [ "${ACC}" = "yes" ]; then log "MEMORY-ACCOUNTING OK"; else log "FAIL: MemoryAccounting not enabled (${ACC:-none})"; fail=1; fi
# Unset MemoryMax == "infinity"; a configured percentage resolves to a finite byte count.
if [ -n "${MAX}" ] && [ "${MAX}" != "infinity" ] && [ "${MAX}" -gt 0 ] 2>/dev/null; then
    log "MEMORYMAX-SET OK (MemoryMax=${MAX} bytes, OOMPolicy=${OOM})"
else
    log "FAIL: MemoryMax not a finite limit (${MAX:-none})"; fail=1
fi
if [ "${OOM}" != "kill" ]; then log "FAIL: OOMPolicy is '${OOM:-none}', expected kill"; fail=1; fi

# POSITIVE-OOM: a single 512M allocation under a transient MemoryMax=64M scope (no swap) cannot succeed —
# the kernel cgroup-OOM-kills it. rc != 0 == contained; rc == 0 == the limit did NOT enforce.
log "POSITIVE-OOM: running a 512M hog under a transient MemoryMax=64M scope (must be contained)"
# Pre-probe: confirm `systemd-run --scope` actually works here, so a non-zero hog exit is attributable to
# the cgroup OOM kill — not to systemd-run failing for an unrelated reason (no bus / permission), which
# would otherwise read as a false POSITIVE-OOM PASS.
probe=0
systemd-run --scope --quiet /bin/true >/dev/null 2>&1 || probe=$?
if [ "${probe}" -ne 0 ]; then
    log "FAIL: systemd-run --scope unavailable (rc=${probe}) — cannot run the POSITIVE-OOM probe"; fail=1
else
    rc=0
    systemd-run --scope --quiet -p MemoryMax=64M -p MemorySwapMax=0 \
        /opt/astromesh/venv/bin/python3 -c 'b = b"x" * (512 * 1024 * 1024)' >/dev/null 2>&1 || rc=$?
    if [ "${rc}" -ne 0 ]; then
        log "POSITIVE-OOM OK (512M hog contained by the cgroup MemoryMax, rc=${rc}; check + host survived)"
    else
        log "FAIL: 512M hog COMPLETED under a 64M cgroup limit — kernel not enforcing memory.max"; fail=1
    fi
fi

if [ "${fail}" -ne 0 ]; then log "MEMORY FAILED"; exit 1; fi
log "MEMORY GATE OK"
