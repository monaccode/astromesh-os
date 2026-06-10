#!/usr/bin/env bash
# Fase 4.2: first boot — issue this node a cert (CN=node_id, SAN=mesh_ip) signed by the baked cluster
# CA, and SEAL the private key to the TPM (PCR 11+12, same tpm2-tools pattern as Fase 3.3). Idempotent.
# Guarded: no-op unless the active runtime.yaml is a mesh profile. The CA key is baked (TEST); prod
# issues out-of-band. node_id/mesh_ip come from the machine-config (exported by the 4.1 oneshot to
# /run/astromesh/mesh/env).
set -uo pipefail
log() { echo "[mesh] $*"; }

RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'mesh:' "${RT}" 2>/dev/null || { log "not a mesh profile; skipping cert issue"; exit 0; }

# shellcheck disable=SC1091
[ -f /run/astromesh/mesh/env ] && . /run/astromesh/mesh/env   # MESH_NODE_ID, MESH_IP, MESH_PEER_IP
NODE_ID="${MESH_NODE_ID:-}"; MESH_IP="${MESH_IP:-}"
[ -n "${NODE_ID}" ] && [ -n "${MESH_IP}" ] || { log "FAIL: missing MESH_NODE_ID/MESH_IP from machine-config"; exit 1; }

CA_CRT=/usr/lib/astromesh-os/mesh/ca.crt
CA_KEY=/usr/lib/astromesh-os/mesh/ca.key
SECRETS=/var/lib/astromesh/secrets
CERT=/var/lib/astromesh/mesh/node.crt        # public, not secret
SEALPUB="${SECRETS}/mesh.seal.pub"
SEALPRIV="${SECRETS}/mesh.seal.priv"
POLICY="${SECRETS}/mesh.policy"
WORK="$(mktemp -d /run/mesh-cert.XXXXXX)"; trap 'rm -rf "${WORK}"' EXIT

if [ -f "${SEALPRIV}" ] && [ -f "${CERT}" ]; then log "already issued+sealed; CERT-SEALED OK"; exit 0; fi

install -d -m 0700 "${SECRETS}"; install -d -m 0755 /var/lib/astromesh/mesh

# 1. Keypair + CSR + cert signed by the cluster CA (CN=node_id, SAN=IP:mesh_ip).
# NOTE: the CA dir (/usr/lib/...) is read-only verity, so the serial (-CAserial) MUST go to a writable
# path, and the ext file is a real file in WORK (not a /dev/fd process substitution) for robustness.
printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth,clientAuth\n' "${MESH_IP}" > "${WORK}/ext.cnf"
openssl ecparam -genkey -name prime256v1 -out "${WORK}/node.key" 2>"${WORK}/e" || { log "FAIL: genkey: $(tr -d '\n' <"${WORK}/e")"; exit 1; }
openssl req -new -key "${WORK}/node.key" -subj "/CN=${NODE_ID}/" -out "${WORK}/node.csr" 2>"${WORK}/e" || { log "FAIL: csr: $(tr -d '\n' <"${WORK}/e")"; exit 1; }
openssl x509 -req -in "${WORK}/node.csr" -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAserial "${WORK}/ca.srl" -CAcreateserial \
    -days 3650 -sha256 -extfile "${WORK}/ext.cnf" -out "${CERT}" 2>"${WORK}/e" || { log "FAIL: sign cert: $(tr -d '\n' <"${WORK}/e")"; exit 1; }

# 2. Seal the private key to the TPM (PCR 11+12), reusing the Fase 3.3 mechanism.
TPM2TOOLS_TCTI=""
for d in /dev/tpmrm0 /dev/tpm0; do if [ -e "$d" ]; then export TPM2TOOLS_TCTI="device:$d"; break; fi; done
[ -n "${TPM2TOOLS_TCTI}" ] || { log "FAIL: no TPM device"; exit 1; }
tpm2_flushcontext -t 2>/dev/null || true; tpm2_flushcontext -s 2>/dev/null || true
tpm2_startauthsession -S "${WORK}/trial.ctx" >/dev/null 2>&1 || { log "FAIL: startauthsession"; exit 1; }
tpm2_policypcr -S "${WORK}/trial.ctx" -l sha256:11,12 -L "${WORK}/policy.digest" >/dev/null 2>&1 \
    || { tpm2_flushcontext "${WORK}/trial.ctx" 2>/dev/null || true; log "FAIL: policypcr"; exit 1; }
tpm2_flushcontext "${WORK}/trial.ctx" 2>/dev/null || true
tpm2_createprimary -C o -g sha256 -G ecc -c "${WORK}/primary.ctx" >/dev/null 2>&1 || { log "FAIL: createprimary"; exit 1; }
tpm2_create -C "${WORK}/primary.ctx" -i "${WORK}/node.key" \
    -u "${WORK}/seal.pub" -r "${WORK}/seal.priv" -L "${WORK}/policy.digest" \
    -a "fixedtpm|fixedparent|adminwithpolicy" >/dev/null 2>&1 || { log "FAIL: tpm2_create (seal)"; exit 1; }
install -m 0600 "${WORK}/seal.pub" "${SEALPUB}"; install -m 0600 "${WORK}/seal.priv" "${SEALPRIV}"; install -m 0600 "${WORK}/policy.digest" "${POLICY}"
sync
log "CERT-SEALED OK (CN=${NODE_ID} SAN=${MESH_IP})"
