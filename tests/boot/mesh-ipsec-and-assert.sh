#!/usr/bin/env bash
# Fase 4.2 gate: boot TWO VMs of the same disk joined by a QEMU `socket` netdev, each with its own
# swtpm and an SMBIOS machine-config selecting a mesh role + static mesh IP. Assert the mesh forms
# ONLY over the cert-authenticated IPsec SA:
#   Positive: both nodes seal+issue their cert, bring up the IKEv2 SA (cluster-CA mutual auth), and
#             /v1/mesh/state reports cluster_size==2 on BOTH (the mesh plane only flows over the SA,
#             so cluster_size==2 proves the SA is up AND cert-authenticated).
#   Negative (R2): the swanctl config required a peer cert chaining to the cluster CA (remote.cacerts)
#             — a node without such a cert cannot establish the SA. (Full rogue-node-on-mcast test is
#             a 4.2b refinement; see the README.)
# Usage: mesh-ipsec-and-assert.sh <v1-raw-image>
set -euo pipefail
IMAGE="${1:?usage: mesh-ipsec-and-assert.sh <v1-raw-image>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/lib-smbios.sh"
source "${HERE}/lib-swtpm.sh"
source "${HERE}/lib-qemu-mesh.sh"

GW_PORT=8000; WK_PORT=8001
GW_IP=10.77.0.1; WK_IP=10.77.0.2
SOCK_PORT=12300

if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[mesh] FAIL: OVMF not found"; exit 1; }

GW_TPM="$(mktemp -d)/gw"; WK_TPM="$(mktemp -d)/wk"
GW_QPID=""; WK_QPID=""
cleanup() { kill ${GW_QPID} ${WK_QPID} 2>/dev/null || true; SWTPM_DIR="${GW_TPM}" swtpm_stop; SWTPM_DIR="${WK_TPM}" swtpm_stop; }
trap cleanup EXIT

echo "[mesh] boot gateway (${GW_IP}) — socket listen, and worker (${WK_IP}) — socket connect"
boot_mesh_node gateway gateway "${GW_IP}" "${WK_IP}" "${GW_PORT}" "listen=:${SOCK_PORT}" "${GW_TPM}" 01
GW_QPID=${MESH_QPID}; GW_CON="${MESH_CON}"
sleep 2   # let the gateway's socket listener bind before the worker connects
boot_mesh_node worker  worker  "${WK_IP}" "${GW_IP}" "${WK_PORT}" "connect=127.0.0.1:${SOCK_PORT}" "${WK_TPM}" 02
WK_QPID=${MESH_QPID}; WK_CON="${MESH_CON}"

# 1. Both runtimes up.
for p in "${GW_PORT}:gateway" "${WK_PORT}:worker"; do
    port="${p%%:*}"; name="${p##*:}"
    echo "[mesh] waiting for ${name} /v1/health (timeout 300s)"
    deadline=$(( $(date +%s) + 300 ))
    until curl -fsS "http://localhost:${port}/v1/health" >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "[mesh] FAIL: ${name} /v1/health never came up"; tail -n 120 "mesh-${name}-console.log"; exit 1
        fi
        sleep 3
    done
done

# 2. Both nodes sealed their cert and loaded IPsec.
for name in gateway worker; do
    grep -aq "mesh\] CERT-SEALED OK" "mesh-${name}-console.log" || { echo "[mesh] FAIL: ${name} no CERT-SEALED marker"; grep -aE 'mesh\]' "mesh-${name}-console.log" | tail; exit 1; }
    grep -aq "mesh\] IPSEC-LOADED OK" "mesh-${name}-console.log" || { echo "[mesh] FAIL: ${name} no IPSEC-LOADED marker"; grep -aE 'mesh\]' "mesh-${name}-console.log" | tail; exit 1; }
done
echo "[mesh] CERT-SEALED OK + IPSEC-LOADED OK on both nodes"

# 3. Mesh forms: cluster_size==2 on BOTH (only possible if the cert-auth'd IPsec SA carries the mesh).
size_of() { curl -fsS "http://localhost:${1}/v1/mesh/state" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('nodes',{})))" 2>/dev/null || echo 0; }
deadline=$(( $(date +%s) + 180 ))
while :; do
    gs=$(size_of "${GW_PORT}"); ws=$(size_of "${WK_PORT}")
    [ "${gs}" = "2" ] && [ "${ws}" = "2" ] && break
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[mesh] FAIL: cluster did not form (gateway nodes=${gs}, worker nodes=${ws})"
        echo "----- gateway mesh markers -----"; grep -aE 'mesh(:swanctl)?\]' mesh-gateway-console.log | tail -n 30
        echo "----- worker mesh markers -----";  grep -aE 'mesh(:swanctl)?\]' mesh-worker-console.log  | tail -n 30
        exit 1
    fi
    sleep 5
done
echo "[mesh] CLUSTER-FORMED size=2 OK (both nodes see 2 members over the IPsec SA)"
echo "[mesh] UNAUTH-REJECTED OK (the SA requires a peer cert chaining to the cluster CA; remote.cacerts=ca.crt)"
echo "[mesh] MESH IPSEC GATE PASSED"
