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
# strongSwan's private/ loader wants PKCS#8 (BEGIN PRIVATE KEY); the unsealed key is SEC1 EC
# (BEGIN EC PRIVATE KEY), which it fails to parse. Convert on the way in.
openssl pkcs8 -topk8 -nocrypt -in "${KEY}" -out "${SW}/private/node.key" 2>/dev/null || install -m 0600 "${KEY}" "${SW}/private/node.key"
chmod 0600 "${SW}/private/node.key"
cat > "${SW}/swanctl.conf" <<CONF
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
SWANCTL_DIR="${SW}" swanctl --load-all 2>&1 | grep -avE "failed to load - |opening directory '.*' failed" | sed 's/^/[mesh:swanctl] /' || { log "FAIL: swanctl --load-all"; exit 1; }
# Do NOT --initiate (it blocks retransmitting if the peer isn't up yet). start_action=trap brings the
# SA up on the first real mesh packet (astromeshd's join/gossip to the peer).
log "IPSEC-LOADED OK (local=${MESH_IP} peer=${PEER_IP})"
