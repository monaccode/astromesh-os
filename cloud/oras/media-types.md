# astromesh-os OCI artifact convention (fixed — changing later is costly)

The image is published to a registry (e.g. Docker Hub) as an **OCI artifact**,
NOT a container image. Consume with `oras pull`, never `docker pull`/`docker run`.

## Tags
- `MAJOR.MINOR.PATCH` (e.g. `0.1.0`) — immutable release.
- `latest` — moves to the newest release.
- Variant suffix (future): `0.1.0-sysext-gpu`.

## Media types
- `application/vnd.astromesh.disk.raw+zstd` — the core disk image, zstd-compressed
  (`.raw.zst`). **Current**, since v0.7.0. `pull.sh` decompresses it, so consumers still
  end up with a `.raw`.
- `application/vnd.astromesh.disk.raw` — the core disk image, uncompressed (`.raw`).
  **Superseded**, used up to and including v0.6.0. Those tags stay as published; `pull.sh`
  passes them through untouched, so old releases keep working.
- `application/vnd.astromesh.sysext.<name>` — (reserved) sysext images, later phases.

### Why the compressed type supersedes the raw one

mkosi emits a **sparse** `.raw`: ~1.8G apparent, ~378M of real blocks. The apparent size is
the fixed partition layout — ESP 512M + root-A 448M + verity-A 32M + var 256M + the empty
A/B spare root 512M + verity-B 32M — so most of the file is holes. ORAS does not preserve
sparseness: pushing the `.raw` verbatim materialised every hole and uploaded ~1880M, ~1.5G
of it zeros. Compressing first collapses the holes (measured: 1880M -> ~406M).

This does not make the OS smaller — it was never big. The residue barely compresses,
because the UKI (kernel + initrd) and the verity hash tree are already-compressed or
high-entropy. The win is not shipping the holes.

## Repo
- `docker.io/<org>/astromesh-os` (set via `ORAS_REPO`).
