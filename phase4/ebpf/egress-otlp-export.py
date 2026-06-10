#!/usr/bin/env python3
# Fase 4.4b: read the eBPF per-flow egress map and push it as OTLP metrics to the local collector.
# Runs as ROOT (astromeshd is non-root and cannot read BPF maps), reusing the venv's OpenTelemetry SDK.
# Guarded: no-op unless the active runtime.yaml has BOTH ebpf egress accounting AND otlp export enabled.
import json, socket, struct, subprocess, sys

RT = "/var/lib/astromesh/runtime.yaml"
MAP = "/sys/fs/bpf/astromesh/flows"
ENDPOINT = "http://127.0.0.1:4317"


def enabled() -> bool:
    try:
        import yaml
        d = yaml.safe_load(open(RT)) or {}
        spec = d.get("spec", {})
        ebpf = spec.get("ebpf", {}).get("egress", {}).get("enabled", False)
        otlp = spec.get("observability", {}).get("otlp", {}).get("enabled", False)
        return bool(ebpf and otlp)
    except Exception:
        return False


def read_flows():
    try:
        out = subprocess.run(
            ["bpftool", "-j", "map", "dump", "pinned", MAP],
            capture_output=True, text=True, timeout=5,
        ).stdout
        data = json.loads(out) if out.strip() else []
    except Exception:
        return []
    flows = []
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
        flows.append((daddr, dport, proto, nbytes, npkts))
    return flows


def main():
    if not enabled():
        return
    from opentelemetry.metrics import Observation
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    from opentelemetry.sdk.resources import Resource

    flows = read_flows()

    def attrs(d, dp, pr):
        return {"daddr": d, "dport": dp, "proto": pr}

    def cb_bytes(options):
        return [Observation(b, attrs(d, dp, pr)) for (d, dp, pr, b, p) in flows]

    def cb_pkts(options):
        return [Observation(p, attrs(d, dp, pr)) for (d, dp, pr, b, p) in flows]

    exporter = OTLPMetricExporter(endpoint=ENDPOINT)
    # Long interval — we drive a single collection+export via force_flush, then exit (oneshot).
    reader = PeriodicExportingMetricReader(exporter, export_interval_millis=3_600_000)
    provider = MeterProvider(
        resource=Resource.create({"service.name": "astromesh-ebpf"}),
        metric_readers=[reader],
    )
    meter = provider.get_meter("astromesh.ebpf")
    meter.create_observable_gauge("astromesh.egress.bytes", callbacks=[cb_bytes], unit="By")
    meter.create_observable_gauge("astromesh.egress.packets", callbacks=[cb_pkts], unit="1")
    provider.force_flush(timeout_millis=8000)
    provider.shutdown()
    print("[ebpf] OTLP-EXPORTED %d flow(s) -> %s" % (len(flows), ENDPOINT))


if __name__ == "__main__":
    main()
