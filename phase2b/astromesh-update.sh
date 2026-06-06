#!/usr/bin/env bash
# A/B updater: download the newest version's split artifacts, write them to the
# INACTIVE root+verity slots, install the new UKI, and reboot into it. No-op (no
# reboot) when the source is unreachable or already on the newest version.
set -uo pipefail

SRC="http://10.0.2.2:8088"
log() { echo "[update] $*"; }

# 1. Newest available version vs running version.
latest=$(curl -fsS "${SRC}/LATEST" 2>/dev/null | tr -dc '0-9')
if [ -z "${latest}" ]; then log "source unreachable / no LATEST; no-op"; exit 0; fi
running=$(tr -dc '0-9' < /usr/lib/astromesh-os/build-version 2>/dev/null)
running=${running:-0}
log "running=${running} latest=${latest}"
if [ "${latest}" -le "${running}" ]; then log "already up to date; no-op"; exit 0; fi

# 2. Active backing partitions of the verity root (data + hash), then pick the
#    INACTIVE partition of each GPT type.
dm=$(basename "$(readlink -f /dev/mapper/root)")
active=""
for s in /sys/block/"${dm}"/slaves/*; do active="${active} /dev/$(basename "${s}")"; done
log "active backing:${active}"

ROOT_TYPE="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
VERITY_TYPE="2c7357ed-ebd2-46d9-aec1-23d437ec2bf5"

inactive_of() {
    local want="$1" path parttype a
    while read -r path parttype; do
        [ "${parttype}" = "${want}" ] || continue
        for a in ${active}; do [ "${path}" = "${a}" ] && continue 2; done
        echo "${path}"; return 0
    done < <(lsblk -b -ln -o PATH,PARTTYPE)
    return 1
}

inactive_root=$(inactive_of "${ROOT_TYPE}")  || { log "FAIL: no inactive root slot"; exit 1; }
inactive_verity=$(inactive_of "${VERITY_TYPE}") || { log "FAIL: no inactive verity slot"; exit 1; }
log "inactive root=${inactive_root} verity=${inactive_verity}"

# 3. Download v_latest split artifacts to tmpfs.
base="astromesh-os-phase0_${latest}"
curl -fsS "${SRC}/${base}.root-x86-64.raw"        -o /run/au-root.raw   || { log "FAIL: download root";   exit 1; }
curl -fsS "${SRC}/${base}.root-x86-64-verity.raw" -o /run/au-verity.raw || { log "FAIL: download verity"; exit 1; }
curl -fsS "${SRC}/${base}.efi"                    -o /run/au-uki.efi    || { log "FAIL: download uki";    exit 1; }

# 4. Write to the inactive slots.
log "writing root image -> ${inactive_root}"
dd if=/run/au-root.raw   of="${inactive_root}"   bs=4M conv=fsync status=none || { log "FAIL: dd root";   exit 1; }
log "writing verity image -> ${inactive_verity}"
dd if=/run/au-verity.raw of="${inactive_verity}" bs=4M conv=fsync status=none || { log "FAIL: dd verity"; exit 1; }

# 5. Install the new UKI into the ESP (its embedded version makes systemd-boot pick it).
esp=$(bootctl --print-esp-path 2>/dev/null || echo /boot)
install -D -m 0644 /run/au-uki.efi "${esp}/EFI/Linux/${base}.efi" || { log "FAIL: install uki"; exit 1; }
log "installed UKI ${esp}/EFI/Linux/${base}.efi"
sync

# 6. Reboot into the new version.
log "update applied; rebooting into v${latest}"
systemctl reboot
