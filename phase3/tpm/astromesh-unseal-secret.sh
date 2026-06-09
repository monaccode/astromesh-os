#!/usr/bin/env bash
# Fase 3.3: each boot, unseal the provider key to a tmpfs env file using raw tpm2-tools with a
# NON-encrypted PCR-policy session (see the seal script / 3.3 spec for why not systemd-creds).
# Succeeds ONLY when PCR 11+12 match the values the secret was sealed against (intact UKI/root and
# untampered runtime cmdline). On mismatch (e.g. appended kernel args -> different PCR 12), the
# policy is not satisfied, the env file is NOT written, and astromeshd starts without the key.
# Logs [seal] markers to console.
set -euo pipefail
log() { echo "[seal] $*"; }

SECRETS=/var/lib/astromesh/secrets
PUB="${SECRETS}/openai.seal.pub"
PRIV="${SECRETS}/openai.seal.priv"
ENVF=/run/astromesh/env
WORK="$(mktemp -d /run/astromesh-unseal.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

rm -f "${ENVF}" 2>/dev/null || true
if [ ! -f "${PRIV}" ] || [ ! -f "${PUB}" ]; then
    log "no sealed blob; no key to unseal (degraded)"
    exit 0
fi
# if-form (not `[ -e ] && ...`): a trailing false `&&` would abort under `set -e`.
TPM2TOOLS_TCTI=""
for d in /dev/tpmrm0 /dev/tpm0; do
    if [ -e "$d" ]; then export TPM2TOOLS_TCTI="device:$d"; break; fi
done
[ -n "${TPM2TOOLS_TCTI}" ] || { log "FAIL: no TPM device (/dev/tpmrm0|tpm0)"; exit 1; }

tpm2_flushcontext -t 2>/dev/null || true
tpm2_flushcontext -s 2>/dev/null || true

# Regenerate the same owner-hierarchy primary and load the sealed object under it.
if ! tpm2_createprimary -C o -g sha256 -G ecc -c "${WORK}/primary.ctx" >/dev/null 2>&1; then
    log "FAIL: createprimary"; exit 1
fi
if ! tpm2_load -C "${WORK}/primary.ctx" -u "${PUB}" -r "${PRIV}" -c "${WORK}/seal.ctx" 2>"${WORK}/load.err"; then
    # A load failure is NOT a tamper signal (it means the parent/blob is wrong, not that PCR 11
    # changed) — surface it as a hard FAIL so the gate doesn't mistake it for a denied unseal.
    log "FAIL: tpm2_load (sealed object): $(tr -d '\n' < "${WORK}/load.err")"; exit 1
fi

# Build a fresh PCR-11+12 policy session. A FAILURE to set up the session (start/policypcr) is an
# infrastructure error, NOT a tamper signal — make it a hard FAIL so the gate (and ops) never
# mistake a broken TPM path for a correctly-denied unseal.
if ! tpm2_startauthsession --policy-session -S "${WORK}/us.ctx" >/dev/null 2>&1; then
    log "FAIL: startauthsession (policy session)"; exit 1
fi
if ! tpm2_policypcr -S "${WORK}/us.ctx" -l sha256:11,12 >/dev/null 2>&1; then
    tpm2_flushcontext "${WORK}/us.ctx" 2>/dev/null || true
    log "FAIL: policypcr (PCR 11/12 unavailable?)"; exit 1
fi
# Now attempt the unseal. ONLY a tpm2_unseal failure (policy not satisfied -> PCR 11/12 changed
# since seal) is the tamper signal: the key stays withheld and the env file is not written.
key=""; unseal_err=""
key="$(tpm2_unseal -p "session:${WORK}/us.ctx" -c "${WORK}/seal.ctx" 2>"${WORK}/unseal.err")" \
    || { key=""; unseal_err="$(tr -d '\n' < "${WORK}/unseal.err")"; }
tpm2_flushcontext "${WORK}/us.ctx" 2>/dev/null || true

if [ -n "${key}" ]; then
    install -d -m 0750 -o root -g astromesh /run/astromesh
    umask 0137
    printf 'OPENAI_API_KEY=%s\n' "${key}" > "${ENVF}"
    chown root:astromesh "${ENVF}"
    chmod 0640 "${ENVF}"
    log "UNSEAL OK (provider key available under intact boot)"
else
    log "TAMPER-BLOCKED OK (TPM unseal denied — PCR 11/12 not intact; key withheld) [${unseal_err}]"
fi
