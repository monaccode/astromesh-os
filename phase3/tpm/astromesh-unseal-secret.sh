#!/usr/bin/env bash
# Fase 3.3: each boot, unseal the provider key to a tmpfs env file. Succeeds ONLY when PCR 11
# matches the value the secret was sealed against (intact boot). On mismatch (tampered boot),
# the env file is NOT written -> astromeshd has no key. Logs [seal] markers to console.
set -uo pipefail
log() { echo "[seal] $*"; }
BLOB=/var/lib/astromesh/secrets/openai.cred
ENVF=/run/astromesh/env

rm -f "${ENVF}" 2>/dev/null || true
if [ ! -f "${BLOB}" ]; then
    log "no sealed blob; no key to unseal (degraded)"
    exit 0
fi
install -d -m 0750 -o root -g astromesh /run/astromesh
if key=$(systemd-creds decrypt --name=astromesh.openai_key "${BLOB}" - 2>/dev/null) && [ -n "${key}" ]; then
    umask 0137
    printf 'OPENAI_API_KEY=%s\n' "${key}" > "${ENVF}"
    chown root:astromesh "${ENVF}"
    chmod 0640 "${ENVF}"
    log "UNSEAL OK (provider key available under intact boot)"
else
    log "TAMPER-BLOCKED OK (TPM unseal denied — PCR 11 not intact; key withheld)"
fi
