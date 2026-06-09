#!/usr/bin/env bash
# Start a persistent software TPM (swtpm) and emit the QEMU flags to attach it. The SAME
# swtpm process/state is reused across the gate's boots so the SRK is stable and the sealed
# blob remains decryptable. Requires the `swtpm` package on the runner.
SWTPM_DIR=""
swtpm_start() {                 # $1 = state dir (created if missing)
    SWTPM_DIR="$1"
    mkdir -p "${SWTPM_DIR}"
    swtpm socket --tpmstate "dir=${SWTPM_DIR}" \
        --ctrl "type=unixio,path=${SWTPM_DIR}/swtpm.sock" \
        --tpm2 --flags startup-clear --daemon --pid "file=${SWTPM_DIR}/swtpm.pid"
    # Give swtpm a moment to create the socket.
    for _ in 1 2 3 4 5; do [ -S "${SWTPM_DIR}/swtpm.sock" ] && break; sleep 0.5; done
}
swtpm_qemu_args() {             # echoes the QEMU args; call after swtpm_start
    printf -- '-chardev socket,id=chrtpm,path=%s/swtpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0' "${SWTPM_DIR}"
}
swtpm_stop() {
    [ -f "${SWTPM_DIR}/swtpm.pid" ] && kill "$(cat "${SWTPM_DIR}/swtpm.pid")" 2>/dev/null || true
}
