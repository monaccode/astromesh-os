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

# 2. Identify the A/B slots and the INACTIVE one. There are exactly two root-data
#    and two root-verity partitions (slot A = index 0, slot B = index 1, in repart
#    order). The active slot is whichever root-data partition backs the mounted /.
ROOT_TYPE="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
VERITY_TYPE="2c7357ed-ebd2-46d9-aec1-23d437ec2bf5"

mapfile -t ROOTS < <(lsblk -ln -o PATH,PARTTYPE | awk -v t="${ROOT_TYPE}" '$2==t{print $1}' | sort)
mapfile -t VERS  < <(lsblk -ln -o PATH,PARTTYPE | awk -v t="${VERITY_TYPE}" '$2==t{print $1}' | sort)
log "root slots: ${ROOTS[*]}  verity slots: ${VERS[*]}"
if [ "${#ROOTS[@]}" -ne 2 ] || [ "${#VERS[@]}" -ne 2 ]; then
    log "FAIL: expected 2 root + 2 verity slots"; exit 1
fi

src=$(findmnt -no SOURCE / 2>/dev/null)
log "root source=${src}"
case "${src}" in
    /dev/mapper/*|/dev/dm-*)  # verity active: resolve to the backing root-data partition
        active_root=$(lsblk -s -ln -o PATH,PARTTYPE "${src}" | awk -v t="${ROOT_TYPE}" '$2==t{print $1; exit}') ;;
    *) active_root="${src}" ;;
esac
log "active root=${active_root}"

if [ "${active_root}" = "${ROOTS[0]}" ]; then
    inactive_root="${ROOTS[1]}"; inactive_verity="${VERS[1]}"
else
    inactive_root="${ROOTS[0]}"; inactive_verity="${VERS[0]}"
fi
log "inactive root=${inactive_root} verity=${inactive_verity}"

# 3+4. Stream each split image straight to its inactive partition (no temp file —
#      the root image is too large for the /run tmpfs).
base="astromesh-os-phase0_${latest}"
log "writing root image -> ${inactive_root}"
curl -fsS "${SRC}/${base}.root-x86-64.raw" | dd of="${inactive_root}" bs=4M conv=fsync status=none \
    || { log "FAIL: write root"; exit 1; }
log "writing verity image -> ${inactive_verity}"
curl -fsS "${SRC}/${base}.root-x86-64-verity.raw" | dd of="${inactive_verity}" bs=4M conv=fsync status=none \
    || { log "FAIL: write verity"; exit 1; }

# 5. Install the new UKI into the ESP (its embedded version makes systemd-boot pick it).
esp=$(bootctl --print-esp-path 2>/dev/null || echo /boot)
mkdir -p "${esp}/EFI/Linux"
curl -fsS "${SRC}/${base}.efi" -o "${esp}/EFI/Linux/${base}.efi" || { log "FAIL: install uki"; exit 1; }
log "installed UKI ${esp}/EFI/Linux/${base}.efi"
sync

# 6. Reboot into the new version.
log "update applied; rebooting into v${latest}"
systemctl reboot
