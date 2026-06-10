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
# The image ships /etc/systemd/network/20-wired.network ([Match] Name=en* eth*, DHCP=yes), which also
# matches the mesh NIC. networkd uses the FIRST matching .network in lexical filename order, so our
# drop-in MUST sort before 20-wired (hence 10-mesh) or the NIC stays on DHCP (no server on the socket
# link -> stuck "configuring", never gets the static IP). RequiredForOnline=no keeps a DHCP-less mesh
# NIC from stalling network-online.target. networkctl reload alone does NOT re-evaluate an already-
# attached link, so reconfigure the link explicitly to drop DHCP and apply the static address.
mkdir -p /run/systemd/network
rm -f /run/systemd/network/30-mesh.network   # supersede any earlier-named drop-in
cat > /run/systemd/network/10-mesh.network <<NET
[Match]
Name=${mesh_if}
[Link]
RequiredForOnline=no
[Network]
Address=${MESH_IP}/24
NET
networkctl reload 2>/dev/null || true
networkctl reconfigure "${mesh_if}" 2>/dev/null || true
# virtio-net offloads the inner TCP checksum (partial); ESP transport mode then encrypts that
# incomplete-checksum packet and the peer drops it on decrypt — so IKE (plaintext UDP) establishes the
# SA but ESP-protected TCP to the peer silently times out. Disable tx/segmentation/receive offload on
# the mesh NIC so inner packets carry complete checksums before encryption.
ethtool -K "${mesh_if}" tx off rx off tso off gso off gro off 2>/dev/null \
    && log "offload disabled on ${mesh_if}" || log "WARN: ethtool offload-off failed on ${mesh_if}"
log "MESH-NET OK (${mesh_if} ${MESH_IP}/24)"
