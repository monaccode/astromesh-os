#!/usr/bin/env bash
# Fase 4.4: load the egress-accounting eBPF program and attach it to astromeshd's cgroup egress hook
# (multi, coexisting with the Fase 3.5 IPAddressDeny filter), pinning the program+map under bpffs.
# Guarded: no-op unless the active runtime.yaml enabled ebpf egress accounting.
set -uo pipefail
log() { echo "[ebpf] $*"; }
RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'ebpf:' "${RT}" 2>/dev/null \
    || { log "not an ebpf boot; skipping"; exit 0; }

OBJ=/usr/lib/astromesh-os/ebpf/egress_acct.bpf.o
PINDIR=/sys/fs/bpf/astromesh
[ -f "${OBJ}" ] || { log "FAIL: missing ${OBJ}"; exit 1; }

# bpffs (systemd usually mounts it; ensure it).
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
install -d "${PINDIR}"

# Discover astromeshd's cgroup v2 dir.
CG=$(systemctl show -p ControlGroup --value astromeshd.service 2>/dev/null)
[ -n "${CG}" ] || { log "FAIL: cannot resolve astromeshd ControlGroup"; exit 1; }
CGDIR="/sys/fs/cgroup${CG}"
[ -d "${CGDIR}" ] || { log "FAIL: cgroup dir not found: ${CGDIR}"; exit 1; }

# Load program + pin maps under bpffs (idempotent: clear a stale pin first).
rm -rf "${PINDIR}/prog" 2>/dev/null || true
bpftool prog loadall "${OBJ}" "${PINDIR}/prog" pinmaps "${PINDIR}" 2>&1 | sed 's/^/[ebpf:bpftool] /' \
    || { log "FAIL: prog loadall"; exit 1; }

# Attach the cgroup_skb/egress program (multi → coexist with systemd's filter).
PROG_PIN="${PINDIR}/prog/egress_acct"
[ -e "${PROG_PIN}" ] || PROG_PIN=$(ls "${PINDIR}/prog"/* 2>/dev/null | head -1)
bpftool cgroup attach "${CGDIR}" egress pinned "${PROG_PIN}" multi 2>&1 | sed 's/^/[ebpf:bpftool] /' \
    || { log "FAIL: cgroup attach (see discovery — try level/mode)"; exit 1; }

log "EBPF-EGRESS-ATTACHED OK (cgroup=${CGDIR} map=${PINDIR}/flows)"
