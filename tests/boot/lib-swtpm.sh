#!/usr/bin/env bash
# Start a software TPM (swtpm) and emit the QEMU flags to attach it. The TPM *state* (owner
# hierarchy seed, NV, persistent handles) lives in a persistent dir so the SRK/owner primary is
# stable across the gate's boots and the sealed blob (stored on the guest disk) stays loadable.
#
# QEMU sends the swtpm a shutdown over the control channel when it exits, so the swtpm daemon
# does NOT survive between boots. We therefore RE-LAUNCH swtpm before each boot from the SAME
# state dir (manufacturing only once). TPM2_Startup(CLEAR) on relaunch resets the volatile PCRs
# — exactly what we want: each boot re-measures PCR 11 via systemd-stub, so a tampered cmdline
# yields a different PCR 11 and the unseal is denied. The owner seed survives Startup(CLEAR)
# (only TPM2_Clear wipes it), so the owner primary regenerates identically and tpm2_load works.
# Requires the swtpm + swtpm-tools packages on the runner.
SWTPM_DIR=""

swtpm_stop() {
    [ -n "${SWTPM_DIR}" ] && [ -f "${SWTPM_DIR}/swtpm.pid" ] || return 0
    local pid; pid="$(cat "${SWTPM_DIR}/swtpm.pid" 2>/dev/null)"
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null || true
    # Wait for it to exit so its state is flushed to disk and the socket is removed before a relaunch.
    for _ in 1 2 3 4 5 6; do kill -0 "${pid}" 2>/dev/null || break; sleep 0.3; done
    rm -f "${SWTPM_DIR}/swtpm.pid" "${SWTPM_DIR}/swtpm.sock"
}

swtpm_launch() {                # (re)start the daemon against the EXISTING state (no manufacture)
    swtpm_stop
    swtpm socket --tpmstate "dir=${SWTPM_DIR}" \
        --ctrl "type=unixio,path=${SWTPM_DIR}/swtpm.sock" \
        --tpm2 --flags startup-clear --daemon --pid "file=${SWTPM_DIR}/swtpm.pid"
    # Give swtpm a moment to create the socket.
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "${SWTPM_DIR}/swtpm.sock" ] && return 0; sleep 0.5; done
    echo "[lib-swtpm] FAIL: swtpm socket never appeared at ${SWTPM_DIR}/swtpm.sock" >&2
    return 1
}

swtpm_start() {                 # $1 = state dir: manufacture (once) + launch — call before boot 1
    SWTPM_DIR="$1"
    mkdir -p "${SWTPM_DIR}"
    # Manufacture the TPM state (EK/SRK + full algorithm profile). --overwrite re-inits so reruns
    # start from a clean, known owner seed. Only done here (boot 1), never on relaunch.
    if command -v swtpm_setup >/dev/null 2>&1; then
        swtpm_setup --tpmstate "${SWTPM_DIR}" --tpm2 --pcr-banks sha256 --overwrite >/dev/null 2>&1 || true
    fi
    swtpm_launch
}

swtpm_qemu_args() {             # echoes the QEMU args; call after swtpm_start/swtpm_launch
    printf -- '-chardev socket,id=chrtpm,path=%s/swtpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0' "${SWTPM_DIR}"
}
