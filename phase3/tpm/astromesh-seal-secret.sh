#!/usr/bin/env bash
# Fase 3.3: on first boot, seal the provisioned provider key to the TPM bound to PCR 11.
# Idempotent: no-op if already sealed. Never persists the plaintext (the SMBIOS credential is
# transient in /run). Logs [seal] markers to console for the gate harness.
set -uo pipefail
log() { echo "[seal] $*"; }
BLOB=/var/lib/astromesh/secrets/openai.cred
CRED="${CREDENTIALS_DIRECTORY:-/run/credentials/astromesh-seal-secret.service}/astromesh.openai_key"

if [ -f "${BLOB}" ]; then
    log "already sealed (${BLOB}); SEALED OK"
    exit 0
fi
if [ ! -s "${CRED}" ]; then
    log "no provisioned credential and no sealed blob; skipping (degraded: no provider key)"
    exit 0
fi
install -d -m 0700 -o root -g root /var/lib/astromesh/secrets
# Bind to PCR 11 (systemd-stub measures the UKI incl. cmdline+roothash there). The blob is
# decryptable only by THIS TPM under the same PCR 11.
if systemd-creds encrypt --name=astromesh.openai_key --with-key=tpm2 --tpm2-pcrs=11 "${CRED}" "${BLOB}"; then
    chmod 0600 "${BLOB}"
    log "SEALED OK (${BLOB} bound to TPM PCR 11)"
else
    log "FAIL: systemd-creds encrypt failed (TPM/PCR unavailable?)"
    exit 1
fi
