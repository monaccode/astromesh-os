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

build_v() {  # $1=version  $2=extra "VAR=val" env (optional)
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
    log "mkosi build v$1 (--force) ${2:-}"
    mkdir -p "${CACHE}"
    ( cd "${WORKDIR}" && env PHASE0_MODE=stub ${2:-} mkosi --image-version="$1" --force --cache-dir="${CACHE}" build )
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

  rollback)
    require_kvm; sync_src; ensure_deb
    build_v 1
    build_v 2 "ASTROMESH_BREAK_HEALTH=1"   # deliberately unhealthy v2
    cd "${WORKDIR}"
    rm -rf update-served && mkdir -p update-served
    cp -L "mkosi.output/${IMAGE_ID}_2.root-x86-64.raw"        update-served/
    cp -L "mkosi.output/${IMAGE_ID}_2.root-x86-64-verity.raw" update-served/
    cp -L "mkosi.output/${IMAGE_ID}_2.efi"                    update-served/
    echo 2 > update-served/LATEST
    ( cd update-served && nohup python3 -m http.server "${HTTP_PORT}" >/tmp/dev-loop-http.log 2>&1 & echo $! > /tmp/dev-loop-http.pid )
    trap 'kill "$(cat /tmp/dev-loop-http.pid 2>/dev/null)" 2>/dev/null || true' EXIT
    sleep 1
    curl -sf "http://127.0.0.1:${HTTP_PORT}/LATEST" >/dev/null || die "HTTP server not serving on ${HTTP_PORT}"
    log "serving UNHEALTHY v2 artifacts on :${HTTP_PORT}"
    qemu-img convert -O qcow2 "mkosi.output/${IMAGE_ID}_1.raw" v1.qcow2
    bash tests/boot/rollback-and-assert.sh v1.qcow2
    ;;

  noshell)
    require_kvm; sync_src; ensure_deb
    # Defensive: a stale http server on :HTTP_PORT (e.g. orphaned by a prior `rollback` run)
    # is reachable from the guest at 10.0.2.2:HTTP_PORT, so this v1 image would auto-update
    # itself on boot and boot the wrong slot — wrecking the no-shell assertion. Kill leftovers.
    pkill -f "http.server ${HTTP_PORT}" 2>/dev/null || true
    # Dev break-glass credential (password: "breakglass"); sha512crypt hash, single-quoted
    # so the $-delimited fields stay literal. Prod injects the real hash via the env var.
    BG_HASH='$6$X017Cf4QG5.ju9DW$hcicgd9vbWYJFQq9Ns6hLLqpF6tE0mAeM3Xzs7d96YDNHIY2R0.GTlUQr/51ogSAZo.L5k7ziLu8IVl7GRXaP0'
    build_v 1 "ASTROMESH_BREAKGLASS_HASH=${BG_HASH}"
    cd "${WORKDIR}"
    # The break-glass driver needs pexpect.
    python3 -c 'import pexpect' 2>/dev/null || apt-get install -y python3-pexpect
    bash tests/boot/noshell-and-assert.sh "mkosi.output/${IMAGE_ID}_1.raw" breakglass
    ;;

  confine)
    require_kvm; sync_src; ensure_deb
    # Defensive: a stale http server on :HTTP_PORT (orphaned by a prior rollback run) is
    # reachable from the guest at 10.0.2.2:HTTP_PORT, so this v1 image would auto-update
    # itself and reboot before the confinement self-check runs. Kill leftovers.
    pkill -f "http.server ${HTTP_PORT}" 2>/dev/null || true
    build_v 1
    cd "${WORKDIR}"
    qemu-img convert -O qcow2 "mkosi.output/${IMAGE_ID}_1.raw" confine.qcow2
    bash tests/boot/confine-and-assert.sh confine.qcow2
    ;;

  sandbox)
    require_kvm; sync_src; ensure_deb
    # Same stale-server guard as confine/tpm: a leftover :HTTP_PORT server would auto-update this
    # v1 and reboot before the sandbox self-check runs.
    pkill -f "http.server ${HTTP_PORT}" 2>/dev/null || true
    build_v 1
    cd "${WORKDIR}"
    qemu-img convert -O qcow2 "mkosi.output/${IMAGE_ID}_1.raw" sandbox.qcow2
    bash tests/boot/sandbox-and-assert.sh sandbox.qcow2
    ;;

  secureboot)
    require_kvm; sync_src; ensure_deb
    pkill -f "http.server ${HTTP_PORT}" 2>/dev/null || true
    build_v 1
    cd "${WORKDIR}"
    # The gate stages secure-boot-enroll on the ESP and converts to qcow2 itself (needs the raw for
    # losetup), so pass the raw image directly.
    bash tests/boot/secureboot-and-assert.sh "mkosi.output/${IMAGE_ID}_1.raw"
    ;;

  tpm)
    require_kvm; sync_src; ensure_deb
    # Same stale-server guard as noshell/confine: a leftover :HTTP_PORT server would auto-update
    # this v1 and reboot before the seal/unseal runs.
    pkill -f "http.server ${HTTP_PORT}" 2>/dev/null || true
    command -v swtpm >/dev/null 2>&1 || apt-get install -y swtpm
    command -v swtpm_setup >/dev/null 2>&1 || apt-get install -y swtpm-tools
    python3 -c 'import pexpect' 2>/dev/null || apt-get install -y python3-pexpect
    build_v 1 "ASTROMESH_SEAL_SECRET=1"   # sealed-secret model: no baked key
    cd "${WORKDIR}"
    # The gate enables the boot menu on the ESP and converts to qcow2 itself (it needs the raw
    # for losetup), so pass the raw image directly.
    bash tests/boot/tpm-seal-and-assert.sh "mkosi.output/${IMAGE_ID}_1.raw"
    ;;

  clean)
    rm -rf "${WORKDIR}/mkosi.output" "${WORKDIR}"/*.qcow2 \
           "${WORKDIR}/ovmf_vars.fd" "${WORKDIR}/qemu-console.log" "${WORKDIR}/update-served"
    log "cleaned build artifacts in ${WORKDIR}"
    ;;

  *)
    die "unknown target '${TARGET}' (use: build | boot | update | rollback | noshell | confine | sandbox | secureboot | tpm | inspect | clean)"
    ;;
esac
log "done (${TARGET})"
