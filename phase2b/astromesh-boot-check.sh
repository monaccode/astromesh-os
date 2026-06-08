#!/usr/bin/env bash
# Health-gated boot assessment for A/B rollback. Runs once, late in boot.
#
# Only acts on a TRIAL boot — systemd-boot boot-counting active, i.e.
# `systemd-bless-boot status` == "indeterminate". The good slot (v1, installed
# without a +tries counter → status "clean") is never touched, so it can never be
# pushed into a reboot loop by this mechanism. On a trial boot:
#   - poll /v1/health; on 200 mark the boot good (counter removed → permanent), OR
#   - on timeout, reboot to consume one boot-counting try. After the tries are
#     exhausted systemd-boot falls back to the previous good UKI (rollback).
set -uo pipefail

BLESS=/usr/lib/systemd/systemd-bless-boot
HEALTH_URL="http://127.0.0.1:8000/v1/health"
HEALTH_TIMEOUT=90
log() { echo "[boot-check] $*"; }

status=$("${BLESS}" status 2>/dev/null || echo unknown)
log "boot status=${status}"
if [ "${status}" != "indeterminate" ]; then
    log "not a trial boot (status=${status}); nothing to assess"
    exit 0
fi

log "trial boot — polling ${HEALTH_URL} for up to ${HEALTH_TIMEOUT}s"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
until curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        log "UNHEALTHY after ${HEALTH_TIMEOUT}s — rebooting to consume a boot try"
        systemctl reboot
        exit 0
    fi
    sleep 3
done
log "HEALTHY — marking this boot good (slot confirmed, no rollback)"
"${BLESS}" good
