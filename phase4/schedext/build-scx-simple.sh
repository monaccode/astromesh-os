#!/usr/bin/env bash
# §12.2a: build scx_simple — the sched_ext example scheduler (BPF struct_ops + a tiny userspace loader) —
# from the sched-ext/scx tree, for baking into the image as the build-input dist/scx_simple. scx is NOT
# packaged in Debian trixie (verified: not in main/contrib/non-free/backports), so we build it from
# source on the host/CI, the same delivery model as the ocb otelcol (phase4/otel) and the Rust eBPF
# daemon (phase4/ebpf/rust). mkosi.postinst.chroot bakes it conditionally (only on schedext builds).
#
# Pinned to v1.0.20: v1.1.0 dropped the C schedulers (incl. scx_simple) in the cargo migration, and its
# meson build was removed. v1.0.20 ships scx_simple under scheds/c with a plain `make` build. The repo
# bundles a per-arch vmlinux.h with the sched_ext types, so the build does NOT need a host kernel that
# has CONFIG_SCHED_CLASS_EXT (the WSL2/CI build kernel does not); scx_simple is CO-RE and relocates
# against the target (guest) kernel's BTF at load time.
#
# Build deps (caller installs): git make clang llvm bpftool libbpf-dev libelf-dev zlib1g-dev
#                               libzstd-dev pkg-config pahole
# Runtime deps on the guest (baked via mkosi.conf Packages): libbpf1 libelf1 zlib1g libzstd1
#
# Usage: build-scx-simple.sh <output-binary-path>
set -euo pipefail

OUT="${1:?usage: build-scx-simple.sh <output-binary-path>}"
SCX_TAG="${SCX_TAG:-v1.0.20}"
SCX_REPO="${SCX_REPO:-https://github.com/sched-ext/scx}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "[build-scx-simple] cloning ${SCX_REPO} @ ${SCX_TAG}"
git clone --depth 1 --branch "${SCX_TAG}" "${SCX_REPO}" "${WORK}/scx"

echo "[build-scx-simple] make scx_simple"
make -C "${WORK}/scx" scx_simple

# Out-of-source build dir is build/scheds/c (see scx root Makefile SCHED_OBJ_DIR).
BIN="${WORK}/scx/build/scheds/c/scx_simple"
[ -x "${BIN}" ] || { echo "[build-scx-simple] ERROR: ${BIN} not produced" >&2; exit 1; }

install -D -m 0755 "${BIN}" "${OUT}"
echo "[build-scx-simple] staged ${OUT} (scx ${SCX_TAG})"
ldd "${OUT}" 2>/dev/null || true
