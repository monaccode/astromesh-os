# astromesh-os

Minimal, immutable, API-only Linux distribution (appliance) whose sole purpose is
running Astromesh AI agents (`astromeshd`). See the design docs in
`docs/superpowers/specs/`.

## Status: Fase 0 (validación del unit)

Phase 0 builds a **standard** Debian-trixie mkosi image that runs Astromesh-core as a
systemd service and answers one agent query. It is intentionally NOT minimal/immutable
yet — that is Fase 1+.

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

Edit `ASTROMESH_REF` in `runtime.pin` to a new commit SHA of `monaccode/astromesh`,
then re-run CI. The image is reproducible from that exact ref.
