#!/usr/bin/env bash
# Fase 3.6 Secure Boot self-check (runs in-guest at boot). Reads the EFI SecureBoot state.
# Under SB-active boots it asserts SB is enabled and emits [secureboot] SB-ENABLED OK. Under a
# non-SB boot (the other gates run on non-secboot OVMF) it emits a degraded log and exits 0 — it
# must NOT fail those boots. Logs markers to console for the gate harness.
set -uo pipefail
log() { echo "[secureboot] $*"; }

# The SecureBoot global EFI variable: 5 bytes (4-byte attrs + 1-byte value); value 1 == enabled.
SBVAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
if [ ! -e "${SBVAR}" ]; then
    log "SB-DISABLED (no SecureBoot EFI var — booted on non-SB firmware; not a failure)"
    exit 0
fi
# Last byte of the var is the value.
val=$(od -An -tu1 "${SBVAR}" 2>/dev/null | tr -s ' ' '\n' | grep -E '.' | tail -1)
log "SecureBoot efivar value=${val:-?}"
if [ "${val}" = "1" ]; then
    log "SB-ENABLED OK"
else
    log "SB-DISABLED (SecureBoot present but off — non-SB boot; not a failure)"
fi
exit 0
