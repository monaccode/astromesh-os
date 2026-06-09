#!/usr/bin/env bash
# Fase 4.1 gate: boot the SAME disk twice with different machine-configs (worker / gateway) injected
# via SMBIOS, and assert each boot (a) applied the role — the runtime loaded the rendered profile,
# proven by /v1/status .services (worker: agents=true,channels=false ; gateway: channels=true,
# agents=false) — and (b) applied the identity (the [mcfg] APPLIED marker reports the node + readback
# hostname). Proves declarative role selection (same disk -> different role, no SSH, no rebuild).
# Usage: machineconfig-and-assert.sh <disk-image>
set -euo pipefail
IMAGE="${1:?usage: machineconfig-and-assert.sh <disk-image>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/lib-smbios.sh"
PORT=8000

if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[mcfg] FAIL: OVMF not found"; exit 1; }

# boot_role <role> <node_id> <expect_services_jq> : boots a fresh copy of the disk with the role's
# machine-config, asserts /v1/status services + the APPLIED marker, then powers off.
boot_role() {
    local role="$1" node="$2" jq_expect="$3"
    local cfg disk vars con
    cfg=$(smbios_machine_config "$(printf 'profile: %s\nnode_id: %s\n' "${role}" "${node}")")
    disk="mcfg-${role}.qcow2"; vars="ovmf_vars_${role}.fd"; con="mcfg-${role}-console.log"
    qemu-img convert -O qcow2 "${IMAGE}" "${disk}"
    qemu-img resize "${disk}" +3G >/dev/null
    cp "${OVMF_VARS_SRC}" "${vars}"
    echo "[mcfg] boot ${role} (node=${node})"
    qemu-system-x86_64 \
        ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,unit=1,file="${vars}" \
        -drive file="${disk}",format=qcow2,if=virtio \
        -smbios "${cfg}" \
        -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
        > "${con}" 2>&1 &
    local qpid=$!
    trap 'kill ${qpid} 2>/dev/null || true' RETURN
    local deadline=$(( $(date +%s) + 240 ))
    until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "[mcfg] FAIL: ${role}: /v1/health never came up"; tail -n 120 "${con}"; return 1
        fi
        sleep 3
    done
    # (a) role applied: the runtime loaded the rendered profile -> /v1/status services match.
    local status; status=$(curl -fsS "http://localhost:${PORT}/v1/status" 2>/dev/null || echo '{}')
    if ! printf '%s' "${status}" | /opt/astromesh/venv/bin/python3 -c "import sys,json; d=json.load(sys.stdin); s=d.get('services',{}); sys.exit(0 if (${jq_expect}) else 1)" 2>/dev/null; then
        echo "[mcfg] FAIL: ${role}: /v1/status services did not match the expected profile"; echo "  status=${status}"; tail -n 60 "${con}"; return 1
    fi
    # (b) identity + profile self-report marker.
    if ! grep -aq "mcfg\] APPLIED profile=${role} node=${node}" "${con}"; then
        echo "[mcfg] FAIL: ${role}: APPLIED marker absent"; grep -aE 'mcfg\]' "${con}" | tail; return 1
    fi
    echo "[mcfg] PASS: ${role}: profile loaded (services match) + identity applied"
    kill ${qpid} 2>/dev/null || true; wait ${qpid} 2>/dev/null || true
    trap - RETURN
}

# worker: agents true, channels false.  gateway: channels true, agents false.
boot_role worker  node-a  "s.get('agents') is True and s.get('channels') is False"
boot_role gateway node-b  "s.get('channels') is True and s.get('agents') is False"
echo "[mcfg] MACHINECONFIG GATE PASSED"
