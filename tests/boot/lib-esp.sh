#!/usr/bin/env bash
# Set systemd-boot loader.conf timeout + editor on a raw disk image's ESP (partition 1),
# so the gate's pexpect driver can interrupt the boot menu over serial and edit the cmdline.
# Usage: esp_set_loader_timeout <raw-image> <seconds>
esp_set_loader_timeout() {
    local img="$1" secs="$2" loop mnt
    loop=$(losetup --show -fP "${img}")
    mnt=$(mktemp -d)
    # Clean up the loop device, mount, and tmpdir on ANY exit from this function — including a
    # `set -e` abort in the caller's shell mid-function — so failures don't leak loop devices
    # or leave the image mounted (which would break the next gate run). RETURN fires on both
    # normal return and error abort within the function.
    trap 'umount "${mnt}" 2>/dev/null || true; rmdir "${mnt}" 2>/dev/null || true; losetup -d "${loop}" 2>/dev/null || true; trap - RETURN' RETURN
    # ESP is the first partition (Type=esp in mkosi.repart).
    mount "${loop}p1" "${mnt}"
    mkdir -p "${mnt}/loader"
    cat > "${mnt}/loader/loader.conf" <<EOF
timeout ${secs}
editor yes
console-mode keep
EOF
    sync
    echo "[lib-esp] set loader timeout=${secs}s editor=yes on ${img}"
}
