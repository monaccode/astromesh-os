#!/usr/bin/env bash
# Asserts the OS is immutable at boot and logs a single marker line to the console.
# - root must be read-only (write attempt fails)
# - dm-verity must be active for the root device
# - /var must be writable
set -uo pipefail

fail() { echo "IMMUTABILITY FAIL: $1"; exit 1; }

# 1. root read-only: writing to /usr (part of the verity root) must fail.
if touch /usr/.imm-probe 2>/dev/null; then
    rm -f /usr/.imm-probe 2>/dev/null || true
    fail "root is writable (/usr)"
fi

# 2. dm-verity active: a device-mapper device whose UUID marks it as a verity
#    target must exist. Read sysfs directly so we do not depend on dmsetup being
#    installed in the minimal image.
if ! grep -lq '^CRYPT-VERITY' /sys/block/dm-*/dm/uuid 2>/dev/null; then
    fail "no active dm-verity device"
fi

# 3. /var writable.
if ! touch /var/.imm-probe 2>/dev/null; then
    fail "/var is not writable"
fi
rm -f /var/.imm-probe 2>/dev/null || true

echo "IMMUTABILITY OK"
