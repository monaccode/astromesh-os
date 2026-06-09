#!/usr/bin/env bash
# Fase 4.1 machine-config: configure the node's role (runtime profile) + identity from a declarative
# machine-config injected via an SMBIOS credential at boot — no SSH, no baked role. Runs BEFORE
# astromeshd. When the credential is ABSENT this is a no-op (exit 0): the astromeshd launcher then
# falls back to the baked /etc/astromesh config (today's behavior), so Fase 0/2/3 gates are unaffected.
# When PRESENT: validate the profile, copy it to /run/astromesh/config/runtime.yaml, symlink the baked
# agents/ there, set the hostname, and persist the node-id. The launcher (astromeshd ExecStart) then
# points --config at /run/astromesh/config.
set -uo pipefail
log() { echo "[mcfg] $*"; }

CRED="${CREDENTIALS_DIRECTORY:-/run/credentials/astromesh-machine-config.service}/astromesh.machine_config"
RUNDIR=/run/astromesh/config
PROFILES_GLOB=(/opt/astromesh/venv/lib/python*/site-packages/astromesh/_bundled/config/profiles)

if [ ! -s "${CRED}" ]; then
    log "no machine-config credential; keeping baked default (/etc/astromesh)"
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
    log "FAIL: machine-config missing required profile/node_id"
    exit 1
fi

# Validate the profile against the bundled profiles (fail-closed on unknown).
profiles_dir="${PROFILES_GLOB[0]}"
profile_file="${profiles_dir}/${profile}.yaml"
if [ ! -f "${profile_file}" ]; then
    log "FAIL: unknown profile=${profile} (not in ${profiles_dir})"
    exit 1
fi

# Render: the profile IS a RuntimeConfig — copy it to the active runtime.yaml on a writable path.
install -d -m 0755 "${RUNDIR}"
install -m 0644 "${profile_file}" "${RUNDIR}/runtime.yaml"
# The runtime loads agents/ from <config_dir>/agents — point at the baked (read-only) agents.
ln -sfn /etc/astromesh/agents "${RUNDIR}/agents"

# Identity: transient hostname (works on read-only /etc) + persisted node-id for the mesh (4.2).
hostnamectl set-hostname "${hostname}" 2>/dev/null || { log "FAIL: hostnamectl set-hostname ${hostname}"; exit 1; }
install -d -m 0750 -o astromesh -g astromesh /var/lib/astromesh 2>/dev/null || true
printf '%s\n' "${node_id}" > /var/lib/astromesh/node-id

log "APPLIED profile=${profile} node=${node_id} hostname=$(hostname) OK"
