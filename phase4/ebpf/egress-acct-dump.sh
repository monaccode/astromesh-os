#!/usr/bin/env bash
# Fase 4.4: dump the per-flow egress accounting map (readable). Prints [ebpf-flow] lines:
#   [ebpf-flow] daddr=<a.b.c.d> dport=<n> proto=<n> bytes=<n> packets=<n>
# Guarded so it is a no-op on non-ebpf boots.
set -uo pipefail
RT=/var/lib/astromesh/runtime.yaml
grep -qE '^[[:space:]]*enabled:[[:space:]]*true' "${RT}" 2>/dev/null && grep -q 'ebpf:' "${RT}" 2>/dev/null \
    || exit 0
MAP=/sys/fs/bpf/astromesh/flows
[ -e "${MAP}" ] || { echo "[ebpf] no flows map yet"; exit 0; }
bpftool -j map dump pinned "${MAP}" 2>/dev/null | python3 - <<'PY'
import sys, json, socket, struct
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in data:
    # bpftool -j prints key/value as either a list of hex byte strings or a {"key":..,"value":..} with
    # "formatted"/"bytes". Handle the common "key"/"value" hex-list form.
    k = e.get("key");  v = e.get("value")
    if isinstance(k, list):
        kb = bytes(int(x, 16) for x in k)
        vb = bytes(int(x, 16) for x in v)
    else:
        continue
    if len(kb) < 7 or len(vb) < 16:
        continue
    daddr = socket.inet_ntoa(kb[0:4])
    dport = struct.unpack("!H", kb[4:6])[0]
    proto = kb[6]
    bytes_, packets = struct.unpack("<QQ", vb[0:16])
    print(f"[ebpf-flow] daddr={daddr} dport={dport} proto={proto} bytes={bytes_} packets={packets}")
PY
