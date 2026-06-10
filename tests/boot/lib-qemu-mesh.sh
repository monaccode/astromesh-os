#!/usr/bin/env bash
# Fase 4.2 mesh gate helper: boot one mesh node. Each node gets its own swtpm (separate state dir),
# its SMBIOS machine-config (profile/node_id/mesh_ip/peer_ip, base64 via lib-smbios.sh), a -nic user
# with hostfwd so the host can read /v1/health + /v1/mesh/state, and a SECOND NIC on a QEMU `socket`
# netdev so the two VMs share an L2 segment (slirp isolates guests; the socket link joins them).
# Sourced by mesh-ipsec-and-assert.sh, which provides OVMF_CODE/OVMF_VARS_SRC/ACCEL/SMP + lib-smbios.

# mesh_smbios <role> <node_id> <mesh_ip> <peer_ip> [seed_ip] -> the -smbios value (machine-config cred)
mesh_smbios() {
    local role="$1" node_id="$2" mesh_ip="$3" peer_ip="$4" seed_ip="${5:-}"
    local y; y="$(printf 'profile: mesh-%s\nnode_id: %s\nmesh_ip: %s\npeer_ip: %s\n' "${role}" "${node_id}" "${mesh_ip}" "${peer_ip}")"
    [ -n "${seed_ip}" ] && y="${y}$(printf 'seed_ip: %s\n' "${seed_ip}")"
    smbios_machine_config "${y}"
}

# boot_mesh_node <role> <node_id> <mesh_ip> <peer_ip> <hostfwd_port> <socket_arg> <swtpm_dir> <mac_suffix> [seed_ip]
#   socket_arg: e.g. 'listen=:12300' (gateway) or 'connect=127.0.0.1:12300' (worker)
# Echoes the QEMU PID via the global MESH_QPID; writes console to mcfg console var MESH_CON.
boot_mesh_node() {
    local role="$1" node_id="$2" mesh_ip="$3" peer_ip="$4" port="$5" sock="$6" swtpm_dir="$7" macsfx="$8" seed_ip="${9:-}"
    local disk="mesh-${role}.qcow2" vars="ovmf_vars_${role}.fd"
    MESH_CON="mesh-${role}-console.log"
    qemu-img convert -O qcow2 "${IMAGE}" "${disk}"
    qemu-img resize "${disk}" +3G >/dev/null
    cp "${OVMF_VARS_SRC}" "${vars}"
    swtpm_start "${swtpm_dir}"
    # shellcheck disable=SC2046
    qemu-system-x86_64 \
        ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
        -global ICH9-LPC.disable_s3=1 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,unit=1,file="${vars}" \
        -drive file="${disk}",format=qcow2,if=virtio \
        $(swtpm_qemu_args) \
        -smbios "$(mesh_smbios "${role}" "${node_id}" "${mesh_ip}" "${peer_ip}" "${seed_ip}")" \
        -nic user,model=virtio-net-pci,hostfwd=tcp::${port}-:8000 \
        -netdev socket,id=mesh,${sock} \
        -device virtio-net-pci,netdev=mesh,mac=52:54:00:00:77:${macsfx} \
        > "${MESH_CON}" 2>&1 &
    MESH_QPID=$!
}
