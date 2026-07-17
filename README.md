<div align="center">

<img src="docs/astromesh-logo.png" alt="Astromesh" width="220" />

# Astromesh OS

**Minimal, immutable, API-only Linux appliance for running Astromesh AI agents.**

[![OS Tag](https://img.shields.io/github/v/tag/monaccode/astromesh-os?sort=semver&label=version&color=fb923c)](https://github.com/monaccode/astromesh-os/tags)
[![CI](https://github.com/monaccode/astromesh-os/actions/workflows/phase0-ci.yml/badge.svg?branch=main)](https://github.com/monaccode/astromesh-os/actions/workflows/phase0-ci.yml)
[![Publish (OCI)](https://github.com/monaccode/astromesh-os/actions/workflows/phase1-publish.yml/badge.svg)](https://github.com/monaccode/astromesh-os/actions/workflows/phase1-publish.yml)
[![Built on Debian trixie](https://img.shields.io/badge/built%20on-Debian%20trixie-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/github/license/monaccode/astromesh-os?color=fb923c)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-Astromesh%20OS-fb923c)](https://monaccode.github.io/astromesh/os/introduction/)

</div>

Minimal, immutable, API-only Linux distribution (appliance) whose sole purpose is
running Astromesh AI agents (`astromeshd`). Versioned **`v0.7.1`** (semver, like the
rest of the ecosystem), mature through **Phase 4 + post-4**. See the
[documentation](https://monaccode.github.io/astromesh/os/introduction/) and the design
docs in `docs/superpowers/specs/`.

## Status

The roadmap (`docs/superpowers/specs/2026-06-05-astromesh-os-decomposition-design.md` §4)
is implemented through **Fase 4 + post-4**, all merged to `main`:

| Fase | Capability | Gate |
|------|-----------|------|
| **0** | Astromesh-core as a systemd service; boot-to-agent | `phase0-ci` (boot + agent, per-push on `main`) |
| **1** | Minimal image (~378 MB of real blocks) + OCI publish via ORAS | `phase1-publish` |
| **2** | Immutability: dm-verity RO root, A/B + automatic rollback | dev-loop `update` |
| **3** | Security: TPM-sealed secrets, no-shell + break-glass, AppArmor, tool sandbox, egress, Secure Boot | `phase3-tpm`, … |
| **4** | Agent-native + fleet: machine-config, mesh mTLS/IPsec, OTel export, eBPF causal egress | `phase4-{machineconfig,mesh,otel,otel-metrics,ebpf-rust,ebpf-control,agent-egress}` |
| **post-4** | §12.3 cgroup memory governance, §12.7 CRIU checkpoint/restore, §12.2a sched_ext¹ | `phase4-{memory,criu,schedext}` |

Runtime pinned to **astromesh `v0.33.1`** (`runtime.pin`) — the Fase 4 OTel/metrics/egress
runtime work, the Moonshot/Kimi OpenAI-compat provider with cache-aware pricing, per-role
model routing, and the core-side OTLP export wiring (`ASTROMESH_OTLP_ENABLED`).

¹ **§12.2a sched_ext** is implemented (guarded loader + `scx_simple`, fail-closed, default
off) but its acceptance gate is **deferred**: Debian's trixie 6.12 kernel ships without
`CONFIG_SCHED_CLASS_EXT` (confirmed empirically; backports 7.0 has it). Closeable by moving
the kernel baseline — see the schedext design doc §0.1. **§12.2b GPU broker** is deferred
(no GPU in the VMs; ships with `sysext-gpu`).

Each phase's acceptance gate builds the image and boots it in QEMU to assert the capability.
`phase0-ci` runs on every push to `main`; the per-phase `phase{3,4}-*` gates run on their
feature branches and via `workflow_dispatch`.

## Build (local, vía Docker)

mkosi and QEMU are Linux-only. On Windows/macOS, build inside a privileged Debian
container:

```bash
docker run --rm -it --privileged -v "$PWD":/work -w /work debian:trixie bash
# inside the container:
apt-get update && apt-get install -y mkosi qemu-system-x86 git python3 python3-pip
# build the runtime .deb first (see .github/workflows/phase0-ci.yml), then:
PHASE0_MODE=stub mkosi build
```

CI (GitHub Actions) is the authoritative gate: see `.github/workflows/phase0-ci.yml`.

## Local dev loop (WSL2 + KVM)

For fast iteration without waiting on CI (and without the TCG flakiness of
GitHub-hosted runners), reproduce the boot/update gate locally in WSL2 with KVM.

**One-time setup (from the Windows host):**

```powershell
wsl --install -d Debian --no-launch
# enable systemd + drvfs metadata, then apply:
wsl -d Debian -u root -- bash -lc "printf '[boot]\nsystemd=true\n\n[automount]\noptions=metadata\n' > /etc/wsl.conf"
wsl --shutdown
# install the same toolset CI uses:
wsl -d Debian -u root -- bash -lc "apt-get update && apt-get install -y mkosi systemd-ukify systemd-boot systemd-boot-efi mtools dosfstools ca-certificates qemu-system-x86 qemu-utils ovmf curl rsync git python3"
# verify KVM is exposed (needs nested virtualization, default on Win11):
wsl -d Debian -u root -- ls -l /dev/kvm
```

If `/dev/kvm` is missing, add `nestedVirtualization=true` under `[wsl2]` in
`%UserProfile%\.wslconfig` and `wsl --shutdown`.

**The runtime `.deb`** (rarely changes — depends only on `runtime.pin`). Fetch the
latest CI build once into `dist/` (run on the Windows side, where `gh` is authed):

```powershell
gh run download -n astromesh-deb -D dist
```

**Run the loop** (as root in WSL — mkosi needs loop devices). The source of truth
stays on `D:\`; the harness rsyncs into `~/astromesh-build` (native ext4) and builds
there (drvfs can't host a mkosi rootfs build):

```powershell
wsl -d Debian -u root -- bash /mnt/d/monaccode/astromesh-os/tests/local/dev-loop.sh update
```

Targets: `build` (image only) · `boot` (single-boot + IMMUTABILITY/health assert) ·
`update` (full A/B v1→v2 gate, default) · `inspect` (UKI roothash vs on-disk verity
PARTUUIDs) · `clean`. CI remains the authoritative gate; the local loop is for fast
iteration before push.

## Bumping the runtime version

`runtime.pin` pins the exact `monaccode/astromesh` ref built into the image — prefer a
release tag (e.g. `ASTROMESH_REF=v0.28.9`) over a floating branch tip. CI checks out that
ref and builds the node `.deb` from source, so the image is reproducible from it. Bump
deliberately — CI fails if the ref can't be resolved.
