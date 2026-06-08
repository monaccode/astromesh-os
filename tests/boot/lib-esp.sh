#!/usr/bin/env bash
# Set systemd-boot loader.conf timeout + editor on a raw disk image's ESP (partition 1),
# so the gate's pexpect driver can interrupt the boot menu over serial and edit the cmdline.
# Usage: esp_set_loader_timeout <raw-image> <seconds>
esp_set_loader_timeout() {
    local img="$1" secs="$2" loop mnt
    loop=$(losetup --show -fP "${img}")
    mnt=$(mktemp -d)
    # ESP is the first partition (Type=esp in mkosi.repart).
    mount "${loop}p1" "${mnt}"
    mkdir -p "${mnt}/loader"
    cat > "${mnt}/loader/loader.conf" <<EOF
timeout ${secs}
editor yes
console-mode keep
EOF
    sync
    umount "${mnt}"
    rmdir "${mnt}"
    losetup -d "${loop}"
    echo "[lib-esp] set loader timeout=${secs}s editor=yes on ${img}"
}
