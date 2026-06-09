#!/usr/bin/env bash
# Helper: build a QEMU -smbios type=11 value that injects a systemd machine-config credential.
# Uses the BINARY (base64) credential form so commas/newlines in the YAML need no QEMU escaping.
# Usage: smbios_machine_config "<yaml string>"  ->  prints  type=11,value=io.systemd.credential.binary:astromesh.machine_config=<b64>
smbios_machine_config() {
    local yaml="$1" b64
    b64=$(printf '%s' "${yaml}" | base64 -w0)
    printf 'type=11,value=io.systemd.credential.binary:astromesh.machine_config=%s' "${b64}"
}
