#!/usr/bin/env bash
# Fase 3.3 gate: prove the provider key is sealed to the TPM and recoverable ONLY under an
# intact boot. Boot 1 (intact, +swtpm +SMBIOS key): seal + unseal + astromeshd health 200.
# Boot 2 (same disk + swtpm, tampered cmdline): unseal must FAIL (PCR 11 differs).
# Usage: tpm-seal-and-assert.sh <disk.qcow2>
set -euo pipefail
IMAGE="${1:?usage: tpm-seal-and-assert.sh <disk.qcow2>}"
PORT=8000
DEVKEY="sk-phase33-sealed-dummy"
TOKEN="astromesh.tamper=1"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/lib-swtpm.sh"

qemu-img resize "${IMAGE}" +3G >/dev/null
OVMF_CODE=""; for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }; done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[tpm] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars_tpm.fd
if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi

swtpm_start "$(pwd)/swtpm-state"
TPM_ARGS="$(swtpm_qemu_args)"
trap 'kill ${QPID:-0} 2>/dev/null || true; swtpm_stop' EXIT

# --- Boot 1: intact, with the SMBIOS-provisioned key ---
echo "[tpm] boot 1: intact (seal + unseal); provisioning key via SMBIOS"
# shellcheck disable=SC2086
timeout 300 qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars_tpm.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    ${TPM_ARGS} \
    -smbios "type=11,value=io.systemd.credential:astromesh.openai_key=${DEVKEY}" \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > tpm-console1.log 2>&1 &
QPID=$!
deadline=$(( $(date +%s) + 240 ))
until grep -aq '\[seal\] UNSEAL OK' tpm-console1.log; do
    grep -aq '\[seal\] FAIL' tpm-console1.log && { echo "[tpm] FAIL: seal/unseal error on intact boot"; tail -n 120 tpm-console1.log; exit 1; }
    [ "$(date +%s)" -ge "${deadline}" ] && { echo "[tpm] FAIL: no UNSEAL OK on intact boot"; tail -n 150 tpm-console1.log; exit 1; }
    sleep 3
done
grep -aq '\[seal\] SEALED OK' tpm-console1.log || { echo "[tpm] FAIL: never sealed on first boot"; exit 1; }
curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1 || { echo "[tpm] FAIL: astromeshd health not 200 with unsealed key"; exit 1; }
echo "[tpm] PASS: sealed + unsealed under intact boot; astromeshd healthy"
kill ${QPID} 2>/dev/null || true; wait ${QPID} 2>/dev/null || true

# --- Boot 2: same disk + same swtpm, tampered cmdline -> PCR 11 differs -> unseal must fail ---
echo "[tpm] boot 2: tampered cmdline (${TOKEN}); unseal must be denied"
cp "${OVMF_VARS_SRC}" ovmf_vars_tpm2.fd
python3 "${HERE}/tpm-tamper-driver.py" "${IMAGE}" "${OVMF_CODE}" ovmf_vars_tpm2.fd "$(pwd)/swtpm-state/swtpm.sock" "${TOKEN}"
echo "[tpm] PASS: secret withheld under tampered boot"
echo "[tpm] TPM SEAL GATE PASSED"
