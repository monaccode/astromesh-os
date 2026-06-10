#!/usr/bin/env bash
# Fase 4.1 machine-config: configure the node's role (runtime profile) + identity from a declarative
# machine-config injected via an SMBIOS credential at boot — no SSH, no baked role. Runs BEFORE
# astromeshd. astromeshd's ExecStart is UNCHANGED (--config /etc/astromesh/); the role is delivered by
# writing /var/lib/astromesh/runtime.yaml, which astromeshd reads through the baked, read-only symlink
# /etc/astromesh/runtime.yaml -> /var/lib/astromesh/runtime.yaml (/var is writable and is already
# allowed by the astromeshd AppArmor profile, so no profile change and no shell wrapper are needed).
# When the credential is ABSENT (or invalid) this clears the rendered runtime.yaml so astromeshd runs
# in its baked "dev" mode (today's behavior) — keeping Fase 0/2/3 gates unaffected.
set -uo pipefail
log() { echo "[mcfg] $*"; }

CRED="${CREDENTIALS_DIRECTORY:-/run/credentials/astromesh-machine-config.service}/astromesh.machine_config"
# /etc/astromesh/runtime.yaml is a baked symlink to this writable path.
RUNTIME_YAML=/var/lib/astromesh/runtime.yaml
PROFILES_GLOB=(/opt/astromesh/venv/lib/python*/site-packages/astromesh/_bundled/config/profiles)

# Be defensive: the writable state dir is normally created by tmpfiles, but ensure it exists.
install -d -m 0750 -o astromesh -g astromesh /var/lib/astromesh 2>/dev/null || true

if [ ! -s "${CRED}" ]; then
    rm -f "${RUNTIME_YAML}"   # clear any stale render -> astromeshd falls back to dev mode (baked)
    log "no machine-config credential; keeping baked default (dev mode)"
    exit 0
fi

# Parse profile/node_id/hostname with PyYAML (robust; the credential is small flow/block YAML).
read -r profile node_id hostname < <(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
profile = str(d.get("profile", "")).strip()
node_id = str(d.get("node_id", "")).strip()
hostname = str(d.get("hostname", "") or node_id).strip()
print(profile, node_id, hostname)
PY
)

if [ -z "${profile}" ] || [ -z "${node_id}" ]; then
    rm -f "${RUNTIME_YAML}"
    log "FAIL: machine-config missing required profile/node_id"
    exit 1
fi

# Sanitize the profile to a bare role name before building a path (no traversal, fail-closed).
case "${profile}" in
    ""|*[!a-z0-9-]*) rm -f "${RUNTIME_YAML}"; log "FAIL: invalid profile name '${profile}'"; exit 1 ;;
esac

profiles_dir="${PROFILES_GLOB[0]}"
if [ ! -d "${profiles_dir}" ]; then
    rm -f "${RUNTIME_YAML}"
    log "FAIL: bundled profiles dir not found (${profiles_dir}) — runtime layout changed?"
    exit 1
fi
profile_file="${profiles_dir}/${profile}.yaml"
if [ ! -f "${profile_file}" ]; then
    rm -f "${RUNTIME_YAML}"
    log "FAIL: unknown profile=${profile} (not in ${profiles_dir})"
    exit 1
fi

# Render: the profile IS a RuntimeConfig — write it as the active runtime.yaml. astromeshd reads it
# via the baked /etc/astromesh/runtime.yaml -> /var/lib/astromesh/runtime.yaml symlink.
install -m 0644 -o astromesh -g astromesh "${profile_file}" "${RUNTIME_YAML}"

# Identity: TRANSIENT hostname only — never the static /etc/hostname, which is on the read-only verity
# root (a static set fails with EROFS). Persist node-id for the mesh (4.2).
hostnamectl set-hostname --transient "${hostname}" 2>/dev/null || { log "FAIL: hostnamectl --transient set-hostname ${hostname}"; exit 1; }
printf '%s\n' "${node_id}" > /var/lib/astromesh/node-id

# Fase 4.2: if the machine-config carries mesh networking (mesh_ip/peer_ip) and the rendered profile
# is a mesh profile, pin the runtime's mesh bind/seeds to concrete IPs (avoids /etc/hosts, read-only)
# and export them for the mesh units (cert issue / static IP / IPsec).
mesh_ip=$(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(str(d.get("mesh_ip","")).strip())
PY
)
peer_ip=$(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(str(d.get("peer_ip","")).strip())
PY
)
if [ -n "${mesh_ip}" ] && grep -q 'mesh:' "${RUNTIME_YAML}" 2>/dev/null; then
    install -d -m 0700 /run/astromesh/mesh
    printf 'MESH_NODE_ID=%s\nMESH_IP=%s\nMESH_PEER_IP=%s\n' "${node_id}" "${mesh_ip}" "${peer_ip}" > /run/astromesh/mesh/env
    /opt/astromesh/venv/bin/python3 - "${RUNTIME_YAML}" "${mesh_ip}" "${peer_ip}" <<'PY'
import sys, yaml
path, mesh_ip, peer_ip = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(path)) or {}
m = d.setdefault("spec", {}).setdefault("mesh", {})
m["bind"] = f"{mesh_ip}:8000"
if peer_ip:
    m["seeds"] = [f"http://{peer_ip}:8000"]
yaml.safe_dump(d, open(path, "w"), sort_keys=False)
PY
    log "mesh net pinned: bind=${mesh_ip}:8000 peer=${peer_ip}"
fi

log "APPLIED profile=${profile} node=${node_id} hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null) OK"
