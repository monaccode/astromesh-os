#!/usr/bin/env bash
# Fase 3.3: on first boot, seal the provisioned provider key to the TPM, bound to PCR 11,
# using raw tpm2-tools with a NON-encrypted PCR-policy session.
#
# Why not systemd-creds: its TPM path opens an AES-128-CFB-encrypted session for parameter
# encryption, a capability the available swtpm/libtpms (0.9.2) does not provide for sessions
# (object-wrapping AES works, session-encryption AES does not). A plain policy session avoids
# that requirement entirely — see the 3.3 spec resume note.
#
# Idempotent: no-op if already sealed. The plaintext is never persisted (the SMBIOS credential
# is transient in /run). Logs [seal] markers to console for the gate harness.
set -euo pipefail
log() { echo "[seal] $*"; }

SECRETS=/var/lib/astromesh/secrets
PUB="${SECRETS}/openai.seal.pub"
PRIV="${SECRETS}/openai.seal.priv"
POLICY="${SECRETS}/openai.policy"
CRED="${CREDENTIALS_DIRECTORY:-/run/credentials/astromesh-seal-secret.service}/astromesh.openai_key"
WORK="$(mktemp -d /run/astromesh-seal.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

if [ -f "${PRIV}" ] && [ -f "${PUB}" ]; then
    log "already sealed (${PRIV}); SEALED OK"
    exit 0
fi
if [ ! -s "${CRED}" ]; then
    log "no provisioned credential and no sealed blob; skipping (degraded: no provider key)"
    exit 0
fi

# Pick a TPM access path (kernel resource manager preferred over the raw char device).
# if-form (not `[ -e ] && ...`): a trailing false `&&` would abort under `set -e`.
TPM2TOOLS_TCTI=""
for d in /dev/tpmrm0 /dev/tpm0; do
    if [ -e "$d" ]; then export TPM2TOOLS_TCTI="device:$d"; break; fi
done
[ -n "${TPM2TOOLS_TCTI}" ] || { log "FAIL: no TPM device (/dev/tpmrm0|tpm0)"; exit 1; }

install -d -m 0700 -o root -g root "${SECRETS}"
# Free any leftover transient objects/sessions so loads don't hit "out of memory for object contexts".
tpm2_flushcontext -t 2>/dev/null || true
tpm2_flushcontext -s 2>/dev/null || true

# 1. Capture the current PCR 11+12 into a policy digest (trial session). systemd-stub measures
#    the UKI's embedded sections (kernel+initrd+embedded cmdline with roothash=) into PCR 11, and
#    the *runtime* (boot-loader-supplied) kernel command line into PCR 12. Binding to BOTH means
#    the secret unseals only under the intact UKI/root (PCR 11) AND an untampered runtime cmdline
#    (PCR 12).
#    NOTE — do NOT reduce this to PCR 11 alone: the gate empirically confirmed that appending a
#    kernel arg via the systemd-boot editor leaves PCR 11 UNCHANGED (PCR-11-only sealing unsealed
#    fine under the tampered cmdline) and only changes PCR 12. PCR 12 is what catches cmdline
#    tampering here.
if ! tpm2_startauthsession -S "${WORK}/trial.ctx" >/dev/null 2>&1; then
    log "FAIL: startauthsession (trial)"; exit 1
fi
if ! tpm2_policypcr -S "${WORK}/trial.ctx" -l sha256:11,12 -L "${WORK}/policy.digest" >/dev/null 2>&1; then
    tpm2_flushcontext "${WORK}/trial.ctx" 2>/dev/null || true
    log "FAIL: policypcr (PCR 11/12 unavailable?)"; exit 1
fi
tpm2_flushcontext "${WORK}/trial.ctx" 2>/dev/null || true

# 2. Deterministic owner-hierarchy primary, regenerated identically every boot from the TPM
#    seed (so the unseal path can reload the sealed object under the same parent).
if ! tpm2_createprimary -C o -g sha256 -G ecc -c "${WORK}/primary.ctx" >/dev/null 2>&1; then
    log "FAIL: createprimary"; exit 1
fi

# 3. Seal the key as a policy-only sealed data object: no userauth (adminwithpolicy) means the
#    PCR 11+12 policy is the ONLY way to recover it. The blob is decryptable only by THIS TPM under
#    the same PCRs. The plaintext arrives via the transient SMBIOS credential and is never persisted.
if tpm2_create -C "${WORK}/primary.ctx" -i "${CRED}" \
        -u "${WORK}/seal.pub" -r "${WORK}/seal.priv" -L "${WORK}/policy.digest" \
        -a "fixedtpm|fixedparent|adminwithpolicy" >/dev/null 2>&1; then
    install -m 0600 "${WORK}/seal.pub"      "${PUB}"
    install -m 0600 "${WORK}/seal.priv"     "${PRIV}"
    install -m 0600 "${WORK}/policy.digest" "${POLICY}"
    # Flush the blob to the /var partition: the secret must survive a reboot/crash, and the gate
    # kills the VM (no clean guest shutdown) between boots — without this the write stays in the
    # guest page cache and is lost, so the next boot finds no sealed blob.
    sync
    log "SEALED OK (${PRIV} bound to TPM PCR 11)"
else
    log "FAIL: tpm2_create (seal) failed (TPM/PCR unavailable?)"
    exit 1
fi
