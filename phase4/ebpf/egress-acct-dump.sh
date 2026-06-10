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

# NOTE: capture the JSON first, then feed it to python via stdin with the script as a -c arg. Do NOT do
# `bpftool ... | python3 - <<'PY'` — the heredoc redirects python's stdin to the script, discarding the
# piped JSON (json.load(sys.stdin) would read empty).
JSON="$(bpftool -j map dump pinned "${MAP}" 2>/dev/null)"
[ -n "${JSON}" ] || { echo "[ebpf] flows map empty"; exit 0; }
printf '%s' "${JSON}" | python3 -c '
import sys, json, socket, struct
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in data:
    k = e.get("key"); v = e.get("value")
    if not isinstance(k, list) or not isinstance(v, list):
        continue
    kb = bytes(int(x, 16) for x in k)
    vb = bytes(int(x, 16) for x in v)
    if len(kb) < 7 or len(vb) < 16:
        continue
    daddr = socket.inet_ntoa(kb[0:4])
    dport = struct.unpack("!H", kb[4:6])[0]
    proto = kb[6]
    nbytes, npkts = struct.unpack("<QQ", vb[0:16])
    print("[ebpf-flow] daddr=%s dport=%d proto=%d bytes=%d packets=%d" % (daddr, dport, proto, nbytes, npkts))
'
