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
read -r mesh_ip peer_ip seed_ip < <(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(str(d.get("mesh_ip","")).strip(), str(d.get("peer_ip","")).strip(), str(d.get("seed_ip","")).strip() or "-")
PY
)
[ "${seed_ip}" = "-" ] && seed_ip=""
if [ -n "${mesh_ip}" ] && grep -q 'mesh:' "${RUNTIME_YAML}" 2>/dev/null; then
    install -d -m 0700 /run/astromesh/mesh
    # peer_ip drives the IPsec SA (remote); seed_ip drives WHO joins WHOM. The gateway gets no seed_ip
    # (standalone -> astromeshd does not block on join()); only the worker seeds to the gateway.
    printf 'MESH_NODE_ID=%s\nMESH_IP=%s\nMESH_PEER_IP=%s\n' "${node_id}" "${mesh_ip}" "${peer_ip}" > /run/astromesh/mesh/env
    /opt/astromesh/venv/bin/python3 - "${RUNTIME_YAML}" "${mesh_ip}" "${seed_ip}" <<'PY'
import sys, yaml
path, mesh_ip, seed_ip = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(path)) or {}
m = d.setdefault("spec", {}).setdefault("mesh", {})
m["bind"] = f"{mesh_ip}:8000"
m["seeds"] = [f"http://{seed_ip}:8000"] if seed_ip else []
yaml.safe_dump(d, open(path, "w"), sort_keys=False)
PY
    log "mesh net pinned: bind=${mesh_ip}:8000 peer=${peer_ip} seed=${seed_ip:-<standalone>}"
fi

# Fase 4.3: if the machine-config asks for OTel export (otel: true), turn on the runtime's OTLP trace
# export. The collector listens on localhost:4317 (the SDK default), so the node needs no endpoint
# unless a fleet downstream is given (left for prod). Guarded by the field's presence/value.
otel=$(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(str(d.get("otel", "")).strip().lower())
PY
)
if [ "${otel}" = "true" ] || [ "${otel}" = "1" ]; then
    /opt/astromesh/venv/bin/python3 - "${RUNTIME_YAML}" <<'PY'
import sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path)) or {}
obs = d.setdefault("spec", {}).setdefault("observability", {})
otlp = obs.setdefault("otlp", {})
otlp["enabled"] = True
# Pin to explicit IPv4 — the image's /etc/hosts maps localhost to BOTH 127.0.0.1 and ::1, and gRPC
# (RFC 6724) prefers ::1, but the baked collector listens IPv4-only on 127.0.0.1, so "localhost" would
# silently hit [::1]:4317 and the export would never arrive.
otlp["endpoint"] = "http://127.0.0.1:4317"
yaml.safe_dump(d, open(path, "w"), sort_keys=False)
PY
    log "otel export enabled (observability.otlp.enabled=true endpoint=127.0.0.1:4317)"
fi

# Fase 4.4: if the machine-config asks for eBPF egress accounting (ebpf_egress: true), set the runtime
# flag so the guarded attach unit runs. Same pattern as the 4.3 otel flag.
ebpf_egress=$(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(str(d.get("ebpf_egress", "")).strip().lower())
PY
)
if [ "${ebpf_egress}" = "true" ] || [ "${ebpf_egress}" = "1" ]; then
    # Fase 4.4e: an optional ebpf_egress_quota (bytes/flow) arms the deny-based enforcement; the Rust
    # daemon writes any flow exceeding it to the eBPF deny map. Absent => no quota (accounting only).
    /opt/astromesh/venv/bin/python3 - "${RUNTIME_YAML}" "${CRED}" <<'PY'
import sys, yaml
path, cred = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(path)) or {}
c = yaml.safe_load(open(cred)) or {}
eg = d.setdefault("spec", {}).setdefault("ebpf", {}).setdefault("egress", {})
eg["enabled"] = True
q = str(c.get("ebpf_egress_quota", "")).strip()
if q:
    eg["quota_bytes"] = int(q)
yaml.safe_dump(d, open(path, "w"), sort_keys=False)
PY
    log "ebpf egress accounting enabled (spec.ebpf.egress.enabled=true)"
fi

# §12.7: if the machine-config asks for CRIU checkpoint/restore (criu: true), set the runtime flag so the
# guarded astromesh-criu-gate unit runs the C/R cycle on this boot. Same pattern as the 4.3 otel flag.
criu=$(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(str(d.get("criu", "")).strip().lower())
PY
)
if [ "${criu}" = "true" ] || [ "${criu}" = "1" ]; then
    /opt/astromesh/venv/bin/python3 - "${RUNTIME_YAML}" <<'PY'
import sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path)) or {}
d.setdefault("spec", {}).setdefault("criu", {})["enabled"] = True
yaml.safe_dump(d, open(path, "w"), sort_keys=False)
PY
    log "criu C/R enabled (spec.criu.enabled=true)"
fi

# §12.2a: if the machine-config asks for sched_ext (sched_ext: true), set the runtime flag so the guarded
# schedext loader+check run on this boot. Same pattern as the 4.3 otel flag.
sched_ext=$(/opt/astromesh/venv/bin/python3 - "${CRED}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(str(d.get("sched_ext", "")).strip().lower())
PY
)
if [ "${sched_ext}" = "true" ] || [ "${sched_ext}" = "1" ]; then
    /opt/astromesh/venv/bin/python3 - "${RUNTIME_YAML}" <<'PY'
import sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path)) or {}
d.setdefault("spec", {}).setdefault("sched_ext", {})["enabled"] = True
yaml.safe_dump(d, open(path, "w"), sort_keys=False)
PY
    log "sched_ext enabled (spec.sched_ext.enabled=true)"
fi

log "APPLIED profile=${profile} node=${node_id} hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null) OK"
