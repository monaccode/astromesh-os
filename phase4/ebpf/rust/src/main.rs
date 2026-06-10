use std::fs;
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::time::Duration;

mod egress_acct {
    include!(concat!(env!("OUT_DIR"), "/egress_acct.skel.rs"));
}
use anyhow::Result;
use egress_acct::*;
use libbpf_rs::skel::{OpenSkel, SkelBuilder};
use libbpf_rs::MapCore;
use opentelemetry::metrics::MeterProvider as _;
use opentelemetry::KeyValue;
use opentelemetry_otlp::WithExportConfig;

const RT: &str = "/var/lib/astromesh/runtime.yaml";
const ENDPOINT: &str = "http://127.0.0.1:4317";
// The daemon's own OTLP export sink — NEVER enforce the quota on it, or the daemon would eventually
// deny its own telemetry pipe and go blind. Kept in sync with ENDPOINT.
const OTLP_ADDR: &str = "127.0.0.1";
const OTLP_PORT: u16 = 4317;

fn enabled() -> bool {
    let s = match fs::read_to_string(RT) {
        Ok(s) => s,
        Err(_) => return false,
    };
    s.contains("ebpf:") && s.contains("otlp:") && s.contains("enabled: true")
}

fn astromeshd_cgroup() -> Option<String> {
    // Test/override hook: pin the accounted cgroup explicitly (used by the host validation harness).
    if let Ok(cg) = std::env::var("ASTROMESH_EBPF_CGROUP") {
        if !cg.is_empty() {
            return Some(cg);
        }
    }
    let out = std::process::Command::new("systemctl")
        .args(["show", "-p", "ControlGroup", "--value", "astromeshd.service"])
        .output()
        .ok()?;
    let cg = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if cg.is_empty() {
        None
    } else {
        Some(format!("/sys/fs/cgroup{cg}"))
    }
}

fn quota_bytes() -> u64 {
    let s = match fs::read_to_string(RT) {
        Ok(s) => s,
        Err(_) => return u64::MAX,
    };
    for line in s.lines() {
        if let Some(rest) = line.trim().strip_prefix("quota_bytes:") {
            if let Ok(n) = rest.trim().parse::<u64>() {
                return n;
            }
        }
    }
    u64::MAX // no quota configured -> deny nothing (4.4d behavior)
}

// Returns (raw_key_bytes, daddr, dport, proto, bytes, packets). The raw key is reused verbatim to write
// the `deny` map (same flow_key layout), so no reconstruction is needed.
fn parse_flows(skel: &EgressAcctSkel) -> Vec<(Vec<u8>, String, u16, u8, u64, u64)> {
    let mut out = Vec::new();
    let map = &skel.maps.flows;
    for key in map.keys() {
        if let Ok(Some(val)) = map.lookup(&key, libbpf_rs::MapFlags::ANY) {
            if key.len() >= 7 && val.len() >= 16 {
                let daddr = format!("{}.{}.{}.{}", key[0], key[1], key[2], key[3]);
                let dport = u16::from_be_bytes([key[4], key[5]]);
                let proto = key[6];
                let nbytes = u64::from_le_bytes(val[0..8].try_into().unwrap());
                let npkts = u64::from_le_bytes(val[8..16].try_into().unwrap());
                out.push((key.clone(), daddr, dport, proto, nbytes, npkts));
            }
        }
    }
    out
}

#[tokio::main]
async fn main() -> Result<()> {
    if !enabled() {
        println!("[otel] astromesh-ebpf: not an ebpf+otlp boot; exiting");
        return Ok(());
    }
    let mut obj = MaybeUninit::uninit();
    let skel = EgressAcctSkelBuilder::default().open(&mut obj)?.load()?;

    let cgpath = astromeshd_cgroup().ok_or_else(|| anyhow::anyhow!("no astromeshd cgroup"))?;
    let cgfile = fs::File::open(&cgpath)?;
    let _link = skel.progs.egress_acct.attach_cgroup(cgfile.as_raw_fd())?;
    println!("[otel] ASTROMESH-EBPF ATTACHED OK (cgroup={cgpath})");

    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_endpoint(ENDPOINT)
        .build()?;
    let reader = opentelemetry_sdk::metrics::PeriodicReader::builder(
        exporter,
        opentelemetry_sdk::runtime::Tokio,
    )
    .build();
    let provider = opentelemetry_sdk::metrics::SdkMeterProvider::builder()
        .with_reader(reader)
        .with_resource(opentelemetry_sdk::Resource::new(vec![KeyValue::new(
            "service.name",
            "astromesh-ebpf",
        )]))
        .build();
    let meter = provider.meter("astromesh.ebpf");
    let g_bytes = meter.u64_gauge("astromesh.egress.bytes").build();
    let g_pkts = meter.u64_gauge("astromesh.egress.packets").build();

    let quota = quota_bytes();
    println!(
        "[ctl] egress quota = {} bytes/flow",
        if quota == u64::MAX { 0 } else { quota }
    );

    loop {
        for (rawkey, daddr, dport, proto, nbytes, npkts) in parse_flows(&skel) {
            let attrs = [
                KeyValue::new("daddr", daddr.clone()),
                KeyValue::new("dport", dport as i64),
                KeyValue::new("proto", proto as i64),
            ];
            g_bytes.record(nbytes, &attrs);
            g_pkts.record(npkts, &attrs);
            // Fase 4.4e: enforcement decision — deny over-quota flows (the eBPF then drops their egress).
            // Exempt the daemon's own telemetry sink so enforcement never blinds the observability pipe.
            let is_own_telemetry = daddr == OTLP_ADDR && dport == OTLP_PORT;
            if nbytes > quota && !is_own_telemetry {
                if skel
                    .maps
                    .deny
                    .update(&rawkey, &[1u8], libbpf_rs::MapFlags::ANY)
                    .is_ok()
                {
                    println!("[ctl] DENY {daddr}:{dport} (bytes={nbytes} > quota={quota})");
                }
            }
        }
        let _ = provider.force_flush();
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}
