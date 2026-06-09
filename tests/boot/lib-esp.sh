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

# Force unattended Secure Boot key auto-enrollment: systemd-boot only auto-enrolls staged keys
# without a prompt when loader.conf has `secure-boot-enroll force`. Operates on the raw image's
# ESP (partition 1). Usage: esp_set_secureboot_enroll <raw-image>
esp_set_secureboot_enroll() {
    local img="$1" loop mnt
    loop=$(losetup --show -fP "${img}")
    mnt=$(mktemp -d)
    trap 'umount "${mnt}" 2>/dev/null || true; rmdir "${mnt}" 2>/dev/null || true; losetup -d "${loop}" 2>/dev/null || true; trap - RETURN' RETURN
    mount "${loop}p1" "${mnt}"
    mkdir -p "${mnt}/loader"
    # Append idempotently; do not clobber timeout/editor lines a prior helper may have written.
    grep -q '^secure-boot-enroll' "${mnt}/loader/loader.conf" 2>/dev/null \
        || echo "secure-boot-enroll force" >> "${mnt}/loader/loader.conf"
    sync
    echo "[lib-esp] set secure-boot-enroll force on ${img}"
}

# Corrupt the signed UKI so its Authenticode signature no longer validates: flip one byte deep in
# the .efi payload (offset 1 MiB is well inside the hashed PE body, not in the Authenticode-excluded
# checksum/cert-table fields). Usage: esp_flip_uki_byte <raw-image>
esp_flip_uki_byte() {
    local img="$1" loop mnt uki
    loop=$(losetup --show -fP "${img}")
    mnt=$(mktemp -d)
    trap 'umount "${mnt}" 2>/dev/null || true; rmdir "${mnt}" 2>/dev/null || true; losetup -d "${loop}" 2>/dev/null || true; trap - RETURN' RETURN
    mount "${loop}p1" "${mnt}"
    uki=$(find "${mnt}/EFI/Linux" -maxdepth 1 -name '*.efi' 2>/dev/null | head -1)
    [ -n "${uki}" ] || { echo "[lib-esp] FAIL: no UKI under EFI/Linux on ${img}" >&2; return 1; }
    # Flip one byte at offset 1 MiB (well inside the hashed PE body / .linux section). XOR the
    # existing byte with 0xff so the change is guaranteed regardless of its current value (a fixed
    # \x01 would be a no-op if the byte already were 0x01, leaving the signature valid).
    local orig flipped
    orig=$(od -An -tx1 -j1048576 -N1 "${uki}" | tr -d ' \n')
    flipped=$(printf '%02x' $(( 0x${orig} ^ 0xff )))
    printf "\\x${flipped}" | dd of="${uki}" bs=1 seek=1048576 count=1 conv=notrunc status=none
    sync
    echo "[lib-esp] flipped one byte in ${uki##*/} on ${img}"
}
