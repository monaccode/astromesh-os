#!/usr/bin/env bash
# Local dev loop — reproduce the phase2b-update CI gate in WSL2 with KVM, in minutes
# and without the TCG flakiness of GitHub-hosted runners.
#
# Run INSIDE WSL2 Debian as root (mkosi needs loop devices / repart):
#   sudo bash tests/local/dev-loop.sh [build|boot|update|clean]
#
# The repo's source of truth stays on D:\ (visible here as /mnt/d/...). drvfs cannot
# host a mkosi rootfs build (no chown/mknod/xattrs), so this rsyncs the source into a
# native ext4 workdir (~/astromesh-build) and builds there. The boot scripts under
# tests/boot/ are reused verbatim — local green ≈ CI green; the only intentional
# difference is KVM here vs. TCG in CI.
set -euo pipefail

TARGET="${1:-update}"
SRC="${ASTROMESH_SRC:-/mnt/d/monaccode/astromesh-os}"
WORKDIR="${ASTROMESH_WORKDIR:-${HOME}/astromesh-build}"
# Persistent mkosi cache for --incremental. Kept OUTSIDE WORKDIR so the rsync
# --delete on each sync does not wipe it.
CACHE="${ASTROMESH_CACHE:-${HOME}/.cache/mkosi-astromesh}"
IMAGE_ID="astromesh-os-phase0"
HTTP_PORT=8088

log() { echo "[dev-loop] $*"; }
die() { echo "[dev-loop] ERROR: $*" >&2; exit 1; }

require_kvm() {
    [ -e /dev/kvm ] || die "no /dev/kvm — enable nestedVirtualization in %UserProfile%\\.wslconfig then 'wsl --shutdown'."
    [ -w /dev/kvm ] || die "/dev/kvm not writable — run this as root (sudo)."
}

sync_src() {
    [ -d "${SRC}" ] || die "source tree not found: ${SRC} (set ASTROMESH_SRC)."
    log "rsync ${SRC} -> ${WORKDIR}"
    mkdir -p "${WORKDIR}"
    rsync -a --delete \
        --exclude '.git/' --exclude 'mkosi.output/' --exclude '_runtime/' \
        --exclude 'mkosi.builddir/' --exclude '*.qcow2' --exclude 'ovmf_vars.fd' \
        --exclude 'qemu-console.log' --exclude 'update-served/' \
        "${SRC}/" "${WORKDIR}/"
    # The Windows working tree may carry CRLF (core.autocrlf=true, no .gitattributes);
    # strip CR from the scripts/configs that run on Linux so bash, the mkosi chroot,
    # and repart/INI parsing don't choke on a trailing \r. Operates on the WORKDIR
    # copy only — never touches the source tree on D:\.
    find "${WORKDIR}" -type f \
        \( -name '*.sh' -o -name '*.chroot' -o -name '*.conf' -o -name '*.service' \
           -o -name '*.network' -o -name 'mkosi.finalize' -o -name 'runtime.pin' \) \
        -exec sed -i 's/\r$//' {} +
    # drvfs (with metadata) hands rsync 0777 on everything, which makes mkosi warn that
    # the .conf files are executable/world-writable. Restore sane modes in the WORKDIR.
    find "${WORKDIR}/mkosi.repart" -name '*.conf' -exec chmod 0644 {} + 2>/dev/null || true
    chmod 0644 "${WORKDIR}"/mkosi.conf 2>/dev/null || true
    chmod 0755 "${WORKDIR}/mkosi.postinst.chroot" "${WORKDIR}/mkosi.finalize" 2>/dev/null || true
}

ensure_deb() {
    ls "${WORKDIR}"/dist/astromesh-node_*_amd64.deb >/dev/null 2>&1 || die \
"no runtime .deb under dist/. Fetch the latest CI build on the Windows side:
   gh run download -n astromesh-deb -D dist
(see README → Local dev loop). The .deb is then picked up by the next sync."
}

build_v() {  # $1=version
    # --force is required: `mkosi build` SKIPS when the output image already exists
    # ("exists already. Use --force to rebuild."), which would silently reuse a stale
    # image and not pick up source changes. Each version (_1/_2) has its own output
    # name, so forcing one does not remove the other.
    # --force: `mkosi build` SKIPS when the output exists (silently reusing a stale
    #   image). --cache-dir caches apt downloads so rebuilds re-fetch nothing.
    # (--incremental is intentionally NOT used: caching the bootstrapped tree breaks
    #  when the package set changes — kmod postinst then fails mid-build.)
    # The fixed repart Seed= (mkosi.conf) keeps /var's filesystem UUID identical across
    # the v1/v2 builds — required because /var is shared across the A/B slots.
    log "mkosi build v$1 (--force)"
    mkdir -p "${CACHE}"
    ( cd "${WORKDIR}" && PHASE0_MODE=stub mkosi --image-version="$1" --force --cache-dir="${CACHE}" build )
}

case "${TARGET}" in
  build)
    sync_src; ensure_deb; build_v 1
    ;;

  boot)
    require_kvm; sync_src; ensure_deb; build_v 1
    cd "${WORKDIR}"
    qemu-img convert -O qcow2 "mkosi.output/${IMAGE_ID}_1.raw" v1.qcow2
    bash tests/boot/run-and-assert.sh v1.qcow2
    ;;

  update)
    require_kvm; sync_src; ensure_deb
    build_v 1
    build_v 2
    cd "${WORKDIR}"
    # Stage + serve the v2 split artifacts exactly like the CI workflow: the in-guest
    # updater pulls them from http://10.0.2.2:8088 (the SLIRP gateway == this host).
    rm -rf update-served && mkdir -p update-served
    cp -L "mkosi.output/${IMAGE_ID}_2.root-x86-64.raw"        update-served/
    cp -L "mkosi.output/${IMAGE_ID}_2.root-x86-64-verity.raw" update-served/
    cp -L "mkosi.output/${IMAGE_ID}_2.efi"                    update-served/
    echo 2 > update-served/LATEST
    ( cd update-served && nohup python3 -m http.server "${HTTP_PORT}" >/tmp/dev-loop-http.log 2>&1 & echo $! > /tmp/dev-loop-http.pid )
    trap 'kill "$(cat /tmp/dev-loop-http.pid 2>/dev/null)" 2>/dev/null || true' EXIT
    sleep 1
    curl -sf "http://127.0.0.1:${HTTP_PORT}/LATEST" >/dev/null || die "HTTP server not serving on ${HTTP_PORT}"
    log "serving v2 artifacts on :${HTTP_PORT}"
    qemu-img convert -O qcow2 "mkosi.output/${IMAGE_ID}_1.raw" v1.qcow2
    bash tests/boot/update-and-assert.sh v1.qcow2
    ;;

  inspect)
    # Verify the verity wiring on the already-built v1 artifacts (no rebuild): the UKI
    # cmdline roothash must equal the concatenation of the root-data and root-verity
    # partition UUIDs (systemd's convention). A mismatch means the initrd will wait for
    # a PARTUUID that never appears → /dev/mapper/root never comes up.
    cd "${WORKDIR}"
    uki="mkosi.output/${IMAGE_ID}_1.efi"
    raw="mkosi.output/${IMAGE_ID}_1.raw"
    [ -f "${uki}" ] && [ -f "${raw}" ] || die "build v1 first (no ${uki}/${raw})."
    UKIFY=$(command -v ukify || echo /usr/lib/systemd/ukify)
    rh=$("${UKIFY}" inspect "${uki}" 2>/dev/null | grep -oE 'roothash=[0-9a-f]{64}' | head -1 | cut -d= -f2)
    [ -n "${rh}" ] || die "no roothash in UKI cmdline."
    data_uuid=$(sfdisk -d "${raw}" | grep -i 'name="root-x86-64"' | grep -oiE 'uuid=[0-9a-f-]{36}' | cut -d= -f2 | tr 'A-F' 'a-f' | tr -d '-')
    hash_uuid=$(sfdisk -d "${raw}" | grep -i 'name="root-x86-64-verity"' | grep -oiE 'uuid=[0-9a-f-]{36}' | cut -d= -f2 | tr 'A-F' 'a-f' | tr -d '-')
    log "roothash   = ${rh}"
    log "data  half = ${rh:0:32}  vs root-data PARTUUID = ${data_uuid}"
    log "hash  half = ${rh:32:32}  vs verity   PARTUUID = ${hash_uuid}"
    if [ "${rh:0:32}" = "${data_uuid}" ] && [ "${rh:32:32}" = "${hash_uuid}" ]; then
        log "PASS: UKI roothash matches on-disk verity partitions (reproducible)."
    else
        die "MISMATCH: UKI roothash != on-disk partitions → verity will fail to come up."
    fi
    ;;

  clean)
    rm -rf "${WORKDIR}/mkosi.output" "${WORKDIR}"/*.qcow2 \
           "${WORKDIR}/ovmf_vars.fd" "${WORKDIR}/qemu-console.log" "${WORKDIR}/update-served"
    log "cleaned build artifacts in ${WORKDIR}"
    ;;

  *)
    die "unknown target '${TARGET}' (use: build | boot | update | inspect | clean)"
    ;;
esac
log "done (${TARGET})"
