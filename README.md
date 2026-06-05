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

## Bumping the runtime version

Edit `ASTROMESH_REF` in `runtime.pin` to a new commit SHA of `monaccode/astromesh`,
then re-run CI. The image is reproducible from that exact ref.
