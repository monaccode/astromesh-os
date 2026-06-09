# Egress governance (Fase 3.5)

`40-egress.conf` puts deny-by-default network filtering on `astromeshd` via systemd
`IPAddressDeny=any` + an `IPAddressAllow=` allowlist. systemd compiles/installs cgroup-BPF programs
to enforce it — real egress-eBPF without custom Rust. Fail-closed (ADR-4): if the filter can't be
applied, `astromesh-egress-check.service` fails and `astromeshd` (which `Requires=` it) won't start.

## Shipped default allowlist

- `localhost` — loopback (stub provider on 127.0.0.1:8081, `/v1/health`, local IPC).
- `10.0.2.0/24` — the QEMU user-net subnet, so the boot gates can reach `/v1/health` via hostfwd.
  **This is for the test harness.** It is RFC1918 and does nothing in a real cloud.

The default ships **no provider CIDRs**, so a real deployment's agent can serve health but cannot
reach the provider until you add them. That is fail-closed by design: preferable to open egress.

## Production

Edit `40-egress.conf` and:

1. Replace `10.0.2.0/24` with the real health-probe / load-balancer source CIDR (or drop it if health
   is scraped over loopback only).
2. Add the provider's egress CIDRs and the DNS resolver, e.g.:

       IPAddressAllow=<dns-resolver-ip>/32
       IPAddressAllow=<provider-cidr-1>
       IPAddressAllow=<provider-cidr-2>

Anthropic does not publish stable CIDRs; source them from your egress proxy / NAT range, or front the
provider with a fixed-IP egress proxy and allow only that. A per-hostname egress proxy and a systemd
generator that reads `/etc/astromesh/egress-allow.conf` are documented fast-follows, not in this MVP.
