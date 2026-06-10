#!/usr/bin/env bash
# Fase 4.2: render swanctl creds + an IKEv2 connection from the issued cert + unsealed key +
# machine-config, modprobe esp4, and bring up the SA to the peer. Guarded. NOTE: the exact swanctl
# syntax/proposals are tuned during gate bring-up (see the plan's Task 6 discovery step).
set -uo pipefail
log() { echo "[mesh] $*"; }
RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'mesh:' "${RT}" 2>/dev/null || { log "not a mesh profile; skipping ipsec"; exit 0; }
# shellcheck disable=SC1091
[ -f /run/astromesh/mesh/env ] && . /run/astromesh/mesh/env
NODE_ID="${MESH_NODE_ID:?}"; MESH_IP="${MESH_IP:?}"; PEER_IP="${MESH_PEER_IP:?}"
CA=/usr/lib/astromesh-os/mesh/ca.crt
CERT=/var/lib/astromesh/mesh/node.crt
KEY=/run/astromesh/mesh/node.key   # unsealed (mesh-cert-unseal)
[ -f "${CERT}" ] && [ -f "${KEY}" ] || { log "FAIL: missing cert/key"; exit 1; }
modprobe esp4 2>/dev/null || true

# /etc/swanctl is read-only verity; point charon at a writable dir (/run) populated here.
SW=/run/swanctl
install -d -m 0755 "${SW}/conf.d" "${SW}/x509ca" "${SW}/x509" "${SW}/private"
install -m 0644 "${CA}"   "${SW}/x509ca/ca.crt"
install -m 0644 "${CERT}" "${SW}/x509/node.crt"
install -m 0600 "${KEY}"  "${SW}/private/node.key"
cat > "${SW}/conf.d/mesh.conf" <<CONF
connections {
  mesh {
    version = 2
    local_addrs  = ${MESH_IP}
    remote_addrs = ${PEER_IP}
    local  { auth = pubkey ; certs = node.crt ; id = ${NODE_ID} }
    remote { auth = pubkey ; cacerts = ca.crt }
    children {
      mesh {
        local_ts  = ${MESH_IP}/32
        remote_ts = ${PEER_IP}/32
        mode = transport
        start_action = trap
      }
    }
    mobike = no
  }
}
CONF
systemctl start strongswan.service 2>/dev/null || systemctl start strongswan-starter.service 2>/dev/null || true
SWANCTL_DIR="${SW}" swanctl --load-all 2>&1 | sed 's/^/[mesh:swanctl] /' || { log "FAIL: swanctl --load-all"; exit 1; }
SWANCTL_DIR="${SW}" swanctl --initiate --child mesh 2>/dev/null || true   # trap also brings it up on first packet
log "IPSEC-LOADED OK (local=${MESH_IP} peer=${PEER_IP})"
