#!/usr/bin/env bash
# Applies an available A/B update and reboots into it. Reboots ONLY if a newer
# version was actually installed — so it is a no-op (no reboot) when the source is
# unreachable (phase0-ci has no server) OR when already running the newest version
# (prevents a reboot loop once booted into v2).
set -uo pipefail

out="$(systemd-sysupdate update 2>&1)"; rc=$?
echo "[autoupdate] (rc=${rc}) ${out}"

if [ "${rc}" -eq 0 ] \
   && echo "${out}" | grep -qiE 'installing|installed|acquiring' \
   && ! echo "${out}" | grep -qi 'already'; then
    echo "[autoupdate] new version installed; rebooting"
    systemctl reboot
else
    echo "[autoupdate] no reboot (no newer version or source unreachable)"
fi
