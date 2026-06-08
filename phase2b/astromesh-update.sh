#!/usr/bin/env bash
# A/B updater: download the newest version's split artifacts, write them to the
# INACTIVE root+verity slots, relabel those partitions' GPT UUIDs to match the new
# verity roothash (so the new UKI's roothash-based discovery finds them on the next
# boot), install the new UKI, and reboot into it. No-op (no reboot) when the source is
# unreachable or already on the newest version.
set -uo pipefail

SRC="http://10.0.2.2:8088"
log() { echo "[update] $*"; }
# Format 32 hex chars as a GPT UUID (8-4-4-4-12).
fmt_uuid() { local h=$1; printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"; }

ROOT_TYPE="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
VERITY_TYPE="2c7357ed-ebd2-46d9-aec1-23d437ec2bf5"

# 1. Newest available version vs running version.
latest=$(curl -fsS "${SRC}/LATEST" 2>/dev/null | tr -dc '0-9')
if [ -z "${latest}" ]; then log "source unreachable / no LATEST; no-op"; exit 0; fi
running=$(tr -dc '0-9' < /usr/lib/astromesh-os/build-version 2>/dev/null)
running=${running:-0}
log "running=${running} latest=${latest}"
if [ "${latest}" -le "${running}" ]; then log "already up to date; no-op"; exit 0; fi

# Don't retry a version that already FAILED its boot-counting trials: systemd-boot
# leaves the exhausted UKI as <base>+0-<done>.efi (0 tries left = bad). Without this,
# after a rollback the booted v1 would see latest>running and re-apply the bad update
# → update→fail→rollback→update loop.
esp=$(bootctl --print-esp-path 2>/dev/null || echo /boot)
base="astromesh-os-phase0_${latest}"
shopt -s nullglob
bad_ukis=( "${esp}/EFI/Linux/${base}+0-"*.efi )
shopt -u nullglob
if [ "${#bad_ukis[@]}" -gt 0 ]; then
    log "v${latest} already failed boot assessment (${bad_ukis[*]}); not retrying"
    exit 0
fi

# 2. Enumerate the two root-data and two root-verity slots (sorted by device path =
#    repart order: slot A then slot B).
mapfile -t ROOTS < <(lsblk -ln -o PATH,PARTTYPE | awk -v t="${ROOT_TYPE}" '$2==t{print $1}' | sort)
mapfile -t VERS  < <(lsblk -ln -o PATH,PARTTYPE | awk -v t="${VERITY_TYPE}" '$2==t{print $1}' | sort)
log "root slots: ${ROOTS[*]}  verity slots: ${VERS[*]}"
if [ "${#ROOTS[@]}" -ne 2 ] || [ "${#VERS[@]}" -ne 2 ]; then
    log "FAIL: expected 2 root + 2 verity slots"; exit 1
fi

# 3. Active root-data partition: the one whose PARTUUID equals the first half of the
#    CURRENTLY RUNNING verity roothash (systemd's convention). The running roothash is
#    on /proc/cmdline and is authoritative — avoids fragile dm-device/slaves resolution
#    (findmnt returns /dev/mapper/root, which lsblk -s can't walk on this stack).
running_rh=$(grep -oE 'roothash=[0-9a-f]{64}' /proc/cmdline | head -1 | cut -d= -f2)
[ -n "${running_rh}" ] || { log "FAIL: no roothash on /proc/cmdline"; exit 1; }
active_uuid=$(fmt_uuid "${running_rh:0:32}")
log "running roothash=${running_rh}"
log "active data PARTUUID=${active_uuid}"
active_root=""
for r in "${ROOTS[@]}"; do
    if [ "$(lsblk -ndo PARTUUID "${r}" 2>/dev/null | tr 'A-F' 'a-f')" = "${active_uuid}" ]; then
        active_root="${r}"; break
    fi
done
log "active root=${active_root}"
[ -n "${active_root}" ] || { log "FAIL: could not determine active root slot"; exit 1; }

if [ "${active_root}" = "${ROOTS[0]}" ]; then
    inactive_root="${ROOTS[1]}"; inactive_verity="${VERS[1]}"
else
    inactive_root="${ROOTS[0]}"; inactive_verity="${VERS[0]}"
fi
log "inactive root=${inactive_root} verity=${inactive_verity}"

# 4. Fetch the new UKI first so we can read its embedded verity roothash (stored as
#    plain ASCII in the PE .cmdline section) — needed to relabel the slot partitions.
TRIES=3
uki_dest="${esp}/EFI/Linux/${base}+${TRIES}.efi"
mkdir -p "${esp}/EFI/Linux"
curl -fsS "${SRC}/${base}.efi" -o "${uki_dest}" || { log "FAIL: download uki"; exit 1; }
rh=$(grep -aoE 'roothash=[0-9a-f]{64}' "${uki_dest}" | head -1 | cut -d= -f2)
[ -n "${rh}" ] || { log "FAIL: no roothash in new UKI"; exit 1; }
log "installed trial UKI ${uki_dest} (${TRIES} tries)"
log "new roothash=${rh}"

# 5. Stream each split image straight to its inactive partition (no temp file — the
#    root image is too large for the /run tmpfs).
log "writing root image -> ${inactive_root}"
curl -fsS "${SRC}/${base}.root-x86-64.raw" | dd of="${inactive_root}" bs=4M conv=fsync status=none \
    || { log "FAIL: write root"; exit 1; }
log "writing verity image -> ${inactive_verity}"
curl -fsS "${SRC}/${base}.root-x86-64-verity.raw" | dd of="${inactive_verity}" bs=4M conv=fsync status=none \
    || { log "FAIL: write verity"; exit 1; }

# 6. Relabel the slot partitions' GPT UUIDs to the new roothash halves (systemd's
#    convention: data part UUID = first half, verity part UUID = second half) so the
#    new UKI's roothash-derived root=PARTUUID discovery finds them on the next boot.
disk="/dev/$(lsblk -ndo PKNAME "${inactive_root}")"
root_pn=$(cat "/sys/class/block/$(basename "${inactive_root}")/partition")
ver_pn=$(cat "/sys/class/block/$(basename "${inactive_verity}")/partition")
root_uuid=$(fmt_uuid "${rh:0:32}")
ver_uuid=$(fmt_uuid "${rh:32:32}")
log "relabel ${disk} p${root_pn}->${root_uuid}  p${ver_pn}->${ver_uuid}"
# --no-reread/--no-tell-kernel: the disk is busy (the active slot is mounted), so the
# kernel can't re-read the partition table now — that's fine, the next boot reads the
# updated GPT from disk.
sfdisk --no-reread --no-tell-kernel --part-uuid "${disk}" "${root_pn}" "${root_uuid}" || { log "FAIL: set root partuuid"; exit 1; }
sfdisk --no-reread --no-tell-kernel --part-uuid "${disk}" "${ver_pn}"  "${ver_uuid}"  || { log "FAIL: set verity partuuid"; exit 1; }
sync

# 7. Reboot into the new version (systemd-boot picks the highest-versioned UKI).
log "update applied; rebooting into v${latest}"
systemctl reboot
