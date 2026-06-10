#!/usr/bin/env bash
# Fase 4.2: each boot — unseal the node's mesh private key to tmpfs (/run/astromesh/mesh/node.key),
# 0600, readable by strongSwan. Same PCR 11+12 policy-session pattern as Fase 3.3 unseal. Guarded.
set -uo pipefail
log() { echo "[mesh] $*"; }
RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'mesh:' "${RT}" 2>/dev/null || { log "not a mesh profile; skipping unseal"; exit 0; }

SECRETS=/var/lib/astromesh/secrets
SEALPUB="${SECRETS}/mesh.seal.pub"; SEALPRIV="${SECRETS}/mesh.seal.priv"
ENC=/var/lib/astromesh/mesh/node.key.enc   # the EC key, encrypted by the TPM-sealed wrap key
OUT=/run/astromesh/mesh/node.key
WORK="$(mktemp -d /run/mesh-unseal.XXXXXX)"; trap 'rm -rf "${WORK}"' EXIT
install -d -m 0700 /run/astromesh/mesh; rm -f "${OUT}"
[ -f "${SEALPRIV}" ] && [ -f "${SEALPUB}" ] && [ -f "${ENC}" ] || { log "no sealed mesh key; degraded"; exit 0; }
TPM2TOOLS_TCTI=""
for d in /dev/tpmrm0 /dev/tpm0; do if [ -e "$d" ]; then export TPM2TOOLS_TCTI="device:$d"; break; fi; done
[ -n "${TPM2TOOLS_TCTI}" ] || { log "FAIL: no TPM device"; exit 1; }
tpm2_flushcontext -t 2>/dev/null || true; tpm2_flushcontext -s 2>/dev/null || true
tpm2_createprimary -C o -g sha256 -G ecc -c "${WORK}/primary.ctx" >/dev/null 2>&1 || { log "FAIL: createprimary"; exit 1; }
tpm2_load -C "${WORK}/primary.ctx" -u "${SEALPUB}" -r "${SEALPRIV}" -c "${WORK}/seal.ctx" >/dev/null 2>&1 || { log "FAIL: tpm2_load"; exit 1; }
tpm2_startauthsession --policy-session -S "${WORK}/us.ctx" >/dev/null 2>&1 || { log "FAIL: startauthsession"; exit 1; }
tpm2_policypcr -S "${WORK}/us.ctx" -l sha256:11,12 >/dev/null 2>&1 || { tpm2_flushcontext "${WORK}/us.ctx" 2>/dev/null || true; log "FAIL: policypcr"; exit 1; }
if tpm2_unseal -p "session:${WORK}/us.ctx" -c "${WORK}/seal.ctx" > "${WORK}/wrap.key" 2>"${WORK}/e"; then
    if openssl enc -d -aes-256-cbc -pbkdf2 -in "${ENC}" -out "${OUT}" -pass "file:${WORK}/wrap.key" 2>"${WORK}/d"; then
        chmod 0600 "${OUT}"; log "KEY-UNSEALED OK"
    else
        rm -f "${OUT}"; log "FAIL: decrypt node key: $(tr -d '\n' < "${WORK}/d")"; exit 1
    fi
else
    rm -f "${OUT}"; log "FAIL: unseal (PCR 11/12 mismatch?): $(tr -d '\n' < "${WORK}/e")"; exit 1
fi
tpm2_flushcontext "${WORK}/us.ctx" 2>/dev/null || true
