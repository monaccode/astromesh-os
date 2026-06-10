#!/usr/bin/env bash
# Fase 4.2: assign the static mesh IP to the QEMU socket-netdev NIC (the second interface). Guarded.
set -uo pipefail
log() { echo "[mesh] $*"; }
RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'mesh:' "${RT}" 2>/dev/null || { log "not a mesh profile; skipping net"; exit 0; }
# shellcheck disable=SC1091
[ -f /run/astromesh/mesh/env ] && . /run/astromesh/mesh/env
[ -n "${MESH_IP:-}" ] || { log "FAIL: no MESH_IP"; exit 1; }
# The mesh NIC is the second ethernet link by name order (slirp NIC is the first, with the DHCP
# default route). The plan's discovery confirms the exact name (e.g. enp0s2 vs enp0s1).
mesh_if=$(ls /sys/class/net | grep -E '^(en|eth)' | sort | sed -n 2p)
[ -n "${mesh_if}" ] || { log "FAIL: no second NIC for mesh"; exit 1; }
mkdir -p /run/systemd/network
cat > /run/systemd/network/30-mesh.network <<NET
[Match]
Name=${mesh_if}
[Network]
Address=${MESH_IP}/24
NET
networkctl reload 2>/dev/null || true
log "MESH-NET OK (${mesh_if} ${MESH_IP}/24)"
