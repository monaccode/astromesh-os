# astromesh-os OCI artifact convention (fixed — changing later is costly)

The image is published to a registry (e.g. Docker Hub) as an **OCI artifact**,
NOT a container image. Consume with `oras pull`, never `docker pull`/`docker run`.

## Tags
- `MAJOR.MINOR.PATCH` (e.g. `0.1.0`) — immutable release.
- `latest` — moves to the newest release.
- Variant suffix (future): `0.1.0-sysext-gpu`.

## Media types
- `application/vnd.astromesh.disk.raw` — the core disk image (`.raw`).
- `application/vnd.astromesh.sysext.<name>` — (reserved) sysext images, later phases.

## Repo
- `docker.io/<org>/astromesh-os` (set via `ORAS_REPO`).
