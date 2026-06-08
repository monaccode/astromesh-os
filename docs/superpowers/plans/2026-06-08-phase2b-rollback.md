# Fase 2b-rollback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic A/B rollback — a freshly-updated slot that fails to reach `/v1/health` within N tries is abandoned and the previous good slot boots again.

**Architecture:** Use systemd-boot's native boot assessment. The updater installs the new UKI with a `+tries` suffix; a `astromesh-boot-check` oneshot, only on a trial boot, marks the slot good on health 200 or reboots to consume a try; after the tries are exhausted systemd-boot falls back to the previous good UKI. The stock unconditional `systemd-bless-boot.service` is masked so blessing happens only on health. A build toggle produces an unhealthy v2 to exercise the rollback gate.

**Tech Stack:** mkosi 25.3 / Debian trixie, systemd-boot UKIs + dm-verity (Fase 2b-update), QEMU/KVM boot harness, the WSL2+KVM local loop (`tests/local/dev-loop.sh`).

**Environment note:** Build/boot run in WSL2 Debian as root (`wsl -d Debian -u root -- bash /mnt/d/monaccode/astromesh-os/tests/local/dev-loop.sh <target>`). `bash -n` lints run on the Windows host. CI is the authoritative gate.

---

## File structure

| File | Responsibility |
|---|---|
| `phase2b/astromesh-boot-check.sh` (new) | Health-gated boot assessment: trial boot → health poll → `bless good` or reboot. |
| `phase2b/astromesh-boot-check.service` (new) | Oneshot that runs the check late in boot. |
| `phase2b/astromesh-update.sh` (modify) | Install the new UKI with `+TRIES`; skip versions already marked bad. |
| `mkosi.postinst.chroot` (modify) | Install+enable boot-check, mask stock bless-boot, honor `ASTROMESH_BREAK_HEALTH`. |
| `mkosi.conf` (modify) | Move `Environment=` to `[Build]` and add `ASTROMESH_BREAK_HEALTH`. |
| `tests/boot/rollback-and-assert.sh` (new) | Rollback gate: broken v2 → tries exhaust → back on v1 + healthy. |
| `tests/local/dev-loop.sh` (modify) | `rollback` target: build broken v2, serve, run the gate. |
| `.github/workflows/phase2b-update.yml` (modify) | `rollback-gate` job (broken v2 → rollback). |

---

## Task 1: Build toggle for an unhealthy v2

**Files:**
- Modify: `mkosi.conf` (the `[Content]` `Environment=` line)
- Modify: `mkosi.postinst.chroot` (add break block near the end, before the final `echo "[postinst] done"`)

- [ ] **Step 1: Move `Environment=` to `[Build]` and add the toggle**

In `mkosi.conf`, delete the `Environment=PHASE0_MODE` line from the `[Content]` section (mkosi warns it belongs in `[Build]`). Then add to the existing `[Build]` section:

```ini
Environment=PHASE0_MODE
        ASTROMESH_BREAK_HEALTH
```

(Listing a bare name passes that variable through from the build invocation's environment.)

- [ ] **Step 2: Honor the toggle in postinst**

In `mkosi.postinst.chroot`, immediately before the final `echo "[postinst] done (mode=${MODE})"` line, add:

```bash
# Test-only: ASTROMESH_BREAK_HEALTH=1 cripples astromeshd so /v1/health never comes up,
# used to exercise the A/B rollback gate. Off by default; never set in normal builds.
if [ "${ASTROMESH_BREAK_HEALTH:-0}" = "1" ]; then
    echo "[postinst] ASTROMESH_BREAK_HEALTH=1 → masking astromeshd (deliberately unhealthy build)"
    systemctl mask astromeshd.service
fi
```

- [ ] **Step 3: Lint**

Run (Windows host): `cd D:/monaccode/astromesh-os && bash -n mkosi.postinst.chroot && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add mkosi.conf mkosi.postinst.chroot
git commit -m "feat(phase2b-rollback): ASTROMESH_BREAK_HEALTH build toggle for unhealthy v2"
```

---

## Task 2: The boot-check script

**Files:**
- Create: `phase2b/astromesh-boot-check.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Health-gated boot assessment for A/B rollback. Runs once, late in boot.
#
# Only acts on a TRIAL boot — systemd-boot boot-counting active, i.e.
# `systemd-bless-boot status` == "indeterminate". The good slot (v1, installed
# without a +tries counter → status "clean") is never touched, so it can never be
# pushed into a reboot loop by this mechanism. On a trial boot:
#   - poll /v1/health; on 200 mark the boot good (counter removed → permanent), OR
#   - on timeout, reboot to consume one boot-counting try. After the tries are
#     exhausted systemd-boot falls back to the previous good UKI (rollback).
set -uo pipefail

BLESS=/usr/lib/systemd/systemd-bless-boot
HEALTH_URL="http://127.0.0.1:8000/v1/health"
HEALTH_TIMEOUT=90
log() { echo "[boot-check] $*"; }

status=$("${BLESS}" status 2>/dev/null || echo unknown)
log "boot status=${status}"
if [ "${status}" != "indeterminate" ]; then
    log "not a trial boot (status=${status}); nothing to assess"
    exit 0
fi

log "trial boot — polling ${HEALTH_URL} for up to ${HEALTH_TIMEOUT}s"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
until curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        log "UNHEALTHY after ${HEALTH_TIMEOUT}s — rebooting to consume a boot try"
        systemctl reboot
        exit 0
    fi
    sleep 3
done
log "HEALTHY — marking this boot good (slot confirmed, no rollback)"
"${BLESS}" good
```

> Port note: `8000` matches the port astromeshd serves and the boot harness forwards
> (`tests/boot/*.sh` use `PORT=8000`). If astromeshd's port ever changes, update both.

- [ ] **Step 2: Lint**

Run: `bash -n phase2b/astromesh-boot-check.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Make executable + commit**

```bash
git update-index --add --chmod=+x phase2b/astromesh-boot-check.sh
git add phase2b/astromesh-boot-check.sh
git commit -m "feat(phase2b-rollback): health-gated boot-check script"
```

---

## Task 3: The boot-check service

**Files:**
- Create: `phase2b/astromesh-boot-check.service`

- [ ] **Step 1: Write the unit**

```ini
[Unit]
Description=Astromesh OS health-gated boot assessment (A/B rollback)
# Run after the system is up so astromeshd has had a chance to start; the script
# itself polls, so it tolerates a slow or absent astromeshd.
After=multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/astromesh-os/astromesh-boot-check.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Validate unit syntax**

Run: `python3 -c "import configparser; c=configparser.ConfigParser(strict=False); c.read('phase2b/astromesh-boot-check.service'); assert c['Service']['Type']=='oneshot'; print('service OK')"`
Expected: `service OK`
(If `python3` is unavailable on the host, run the same via WSL: `wsl -d Debian -- python3 -c "..."`.)

- [ ] **Step 3: Commit**

```bash
git add phase2b/astromesh-boot-check.service
git commit -m "feat(phase2b-rollback): boot-check oneshot service"
```

---

## Task 4: Wire boot-check into the image + mask stock bless-boot

**Files:**
- Modify: `mkosi.postinst.chroot` (after the existing "Fase 2b: custom A/B updater" install block, near the immutability-check install)

- [ ] **Step 1: Add install + enable + mask**

In `mkosi.postinst.chroot`, immediately after the three `astromesh-update` install lines (the `systemctl enable astromesh-update.service` line), add:

```bash
# Fase 2b-rollback: health-gated boot assessment.
install -m 0755 "${SRC}/phase2b/astromesh-boot-check.sh" /usr/lib/astromesh-os/astromesh-boot-check.sh
install -m 0644 "${SRC}/phase2b/astromesh-boot-check.service" /etc/systemd/system/astromesh-boot-check.service
systemctl enable astromesh-boot-check.service
# The stock systemd-bless-boot.service marks the booted entry good UNCONDITIONALLY when
# boot-complete.target is reached — which a booted-but-unhealthy slot also reaches. Mask
# it so blessing happens ONLY via astromesh-boot-check (on health). systemd-boot still
# decrements the +tries counter on its own; only the "mark good" is ours.
systemctl mask systemd-bless-boot.service
```

- [ ] **Step 2: Lint**

Run: `bash -n mkosi.postinst.chroot && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add mkosi.postinst.chroot
git commit -m "feat(phase2b-rollback): install/enable boot-check, mask stock bless-boot"
```

---

## Task 5: Updater installs the UKI with `+tries` and skips known-bad versions

**Files:**
- Modify: `phase2b/astromesh-update.sh`

- [ ] **Step 1: Add the re-update guard (break the rollback loop)**

After the version comparison block (the lines that end with `if [ "${latest}" -le "${running}" ]; then log "already up to date; no-op"; exit 0; fi`), insert:

```bash
# Don't retry a version that already FAILED its boot-counting trials: systemd-boot
# leaves the exhausted UKI as <base>+0-<done>.efi (0 tries left = bad). Without this,
# after a rollback the booted v1 would see latest>running and re-apply the bad update
# → update→fail→rollback→update loop.
esp=$(bootctl --print-esp-path 2>/dev/null || echo /boot)
base="astromesh-os-phase0_${latest}"
shopt -s nullglob
bad_ukis=( "${esp}/EFI/Linux/${base}+0-"*.efi )
shopt -u nullglob
if [ "${#bad_ukis[@]}" -gt 0 ]; then
    log "v${latest} already failed boot assessment (${bad_ukis[*]}); not retrying"
    exit 0
fi
```

- [ ] **Step 2: Remove the now-duplicate `esp=`/`base=` definitions in step 4**

The UKI-download block (step "4." in the script) currently defines `base=` and `esp=` again. Delete those two lines there (they are now set above). The block changes from:

```bash
base="astromesh-os-phase0_${latest}"
esp=$(bootctl --print-esp-path 2>/dev/null || echo /boot)
mkdir -p "${esp}/EFI/Linux"
curl -fsS "${SRC}/${base}.efi" -o "${esp}/EFI/Linux/${base}.efi" || { log "FAIL: download uki"; exit 1; }
rh=$(grep -aoE 'roothash=[0-9a-f]{64}' "${esp}/EFI/Linux/${base}.efi" | head -1 | cut -d= -f2)
```

to:

```bash
TRIES=3
uki_dest="${esp}/EFI/Linux/${base}+${TRIES}.efi"
mkdir -p "${esp}/EFI/Linux"
curl -fsS "${SRC}/${base}.efi" -o "${uki_dest}" || { log "FAIL: download uki"; exit 1; }
rh=$(grep -aoE 'roothash=[0-9a-f]{64}' "${uki_dest}" | head -1 | cut -d= -f2)
```

- [ ] **Step 3: Update the UKI install log line + the final log**

Later in the same block the script logs `installed UKI ...` — there is no separate install step now (the curl wrote straight to `uki_dest`). Ensure the log references the trial UKI; change the log line that mentions the UKI path to:

```bash
log "installed trial UKI ${uki_dest} (${TRIES} tries)"
```

(If that exact log line does not exist in the current script, add it right after the `rh=` extraction succeeds — after the `[ -n "${rh}" ] || { ...; }` check.)

- [ ] **Step 4: Lint**

Run: `bash -n phase2b/astromesh-update.sh && echo OK`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add phase2b/astromesh-update.sh
git commit -m "feat(phase2b-rollback): install trial UKI with +tries; skip known-bad versions"
```

---

## Task 6: The rollback gate harness

**Files:**
- Create: `tests/boot/rollback-and-assert.sh`

- [ ] **Step 1: Write the harness**

```bash
#!/usr/bin/env bash
# A/B rollback gate: boot v1, let the guest auto-update to a deliberately UNHEALTHY v2
# (served over HTTP), and assert the boot-counting rolls back to v1.
# Usage: tests/boot/rollback-and-assert.sh <v1-disk-image>
# Requires: an HTTP server on :8088 serving the BROKEN v2 split artifacts + LATEST=2
# (the caller sets this up — see tests/local/dev-loop.sh / the CI job).
set -euo pipefail

IMAGE="${1:?usage: rollback-and-assert.sh <disk-image>}"
PORT=8000
# 3 trials * (90s health timeout + boot) + final v1 boot. Generous for TCG.
TIMEOUT=600

qemu-img resize "${IMAGE}" +4G >/dev/null

if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; SMP=2; else ACCEL="-accel tcg,thread=multi"; SMP=4; fi

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { OVMF_VARS_SRC="$v"; break; }
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[rollback] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars.fd

echo "[rollback] starting QEMU (persistent, reboots allowed)"
qemu-system-x86_64 \
    ${ACCEL} -machine q35 -m 2048 -smp ${SMP} -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file=ovmf_vars.fd \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > qemu-console.log 2>&1 &
QEMU_PID=$!
trap 'kill ${QEMU_PID} 2>/dev/null || true' EXIT

wait_health() {
    local deadline=$(( $(date +%s) + $1 ))
    until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
        [ "$(date +%s)" -ge "${deadline}" ] && return 1
        sleep 3
    done
}

echo "[rollback] waiting for initial v1 health"
wait_health 180 || { echo "[rollback] FAIL: v1 never came up"; tail -n 120 qemu-console.log; exit 1; }
echo "[rollback] PASS: v1 up before update"

echo "[rollback] waiting for the bad-v2 attempt + rollback to v1 (up to ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
# Success = the unhealthy v2 was tried (boot-check logged an unhealthy reboot) AND the
# system is back to a healthy v1: the LATEST ASTROMESH_BUILD marker is 1 and health 200.
while true; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[rollback] FAIL: did not observe rollback to healthy v1 in time"
        echo "----- boot-check / markers -----"; grep -aE 'boot-check|ASTROMESH_BUILD' qemu-console.log || true
        echo "----- console tail -----"; tail -n 150 qemu-console.log || true
        exit 1
    fi
    grep -q 'boot-check.*UNHEALTHY' qemu-console.log || { sleep 5; continue; }   # v2 was tried & failed
    last_ver=$(grep -aoE 'ASTROMESH_BUILD=[0-9]+' qemu-console.log | tail -1 | cut -d= -f2)
    [ "${last_ver}" = "1" ] || { sleep 5; continue; }                           # back on v1
    curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1 || { sleep 5; continue; }  # and healthy
    break
done
echo "[rollback] PASS: bad v2 was tried, system rolled back to a healthy v1"
echo "[rollback] ROLLBACK GATE PASSED"
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/boot/rollback-and-assert.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Make executable + commit**

```bash
git update-index --add --chmod=+x tests/boot/rollback-and-assert.sh
git add tests/boot/rollback-and-assert.sh
git commit -m "test(phase2b-rollback): rollback gate harness"
```

---

## Task 7: `rollback` target in the local loop

**Files:**
- Modify: `tests/local/dev-loop.sh` (add a `rollback` case; teach `build_v` to pass extra env)

- [ ] **Step 1: Let `build_v` accept extra build env**

Change the `build_v` function so an optional second argument is exported for the build. Replace:

```bash
build_v() {  # $1=version
    # ... comments ...
    log "mkosi build v$1 (--force)"
    mkdir -p "${CACHE}"
    ( cd "${WORKDIR}" && PHASE0_MODE=stub mkosi --image-version="$1" --force --cache-dir="${CACHE}" build )
}
```

with:

```bash
build_v() {  # $1=version  $2=extra "VAR=val" env (optional)
    # --force: mkosi skips when the output exists; --cache-dir reuses apt downloads.
    # The fixed repart Seed= (mkosi.conf) keeps /var's UUID stable across v1/v2.
    log "mkosi build v$1 (--force) ${2:-}"
    mkdir -p "${CACHE}"
    ( cd "${WORKDIR}" && env PHASE0_MODE=stub ${2:-} mkosi --image-version="$1" --force --cache-dir="${CACHE}" build )
}
```

- [ ] **Step 2: Add the `rollback` target**

Add a new `case` arm before `clean)`:

```bash
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
```

- [ ] **Step 3: Add `rollback` to the usage/unknown-target message**

Change the final `die` line to list it:

```bash
    die "unknown target '${TARGET}' (use: build | boot | update | rollback | inspect | clean)"
```

- [ ] **Step 4: Lint**

Run: `bash -n tests/local/dev-loop.sh && echo OK`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add tests/local/dev-loop.sh
git commit -m "feat(local-dev): dev-loop rollback target (unhealthy v2)"
```

---

## Task 8: Run the rollback gate locally (integration validation)

This is the real test for Tasks 1-7. No code; run the gate end-to-end on the WSL2+KVM loop.

- [ ] **Step 1: Ensure a clean WSL build state**

Run (PowerShell): `wsl -d Debian -u root -- bash -lc "rm -rf /root/astromesh-build/mkosi.output; echo clean"`
Expected: `clean`

- [ ] **Step 2: Run the rollback gate**

Run (PowerShell, background — builds v1 + unhealthy v2 + boots): start
`wsl -d Debian -u root -- bash /mnt/d/monaccode/astromesh-os/tests/local/dev-loop.sh rollback`
redirecting stdout/stderr to temp files, then poll the log for a terminal marker.

- [ ] **Step 3: Confirm the gate passes**

Expected in the output: `[rollback] ROLLBACK GATE PASSED`.
If it fails, read `~/astromesh-build/qemu-console.log` in WSL and check, in order:
- `[boot-check] boot status=indeterminate` appeared on the v2 trial boots (counting active),
- `[boot-check] UNHEALTHY ... rebooting` appeared (health gate worked),
- the UKI went `_2+3.efi` → `_2+2-1` → ... → `_2+0-3.efi` in `/boot/EFI/Linux` (systemd-boot decremented),
- the final boot logged `ASTROMESH_BUILD=1` and health 200 (rollback landed),
- the updater logged `already failed boot assessment; not retrying` (no re-update loop).
Then fix the specific component and re-run. Do NOT proceed to CI until the local gate is green.

- [ ] **Step 4: (No commit — validation only)**

---

## Task 9: CI rollback gate

**Files:**
- Modify: `.github/workflows/phase2b-update.yml`

- [ ] **Step 1: Build an unhealthy v2 image in `build-images`**

In the `build-images` job, after the existing "Build v2 (split artifacts)" + stage steps, add a step that builds the broken v2 and stages it under a separate dir:

```yaml
      - name: Build v2-broken (unhealthy, for rollback gate)
        env:
          PHASE0_MODE: stub
          ASTROMESH_BREAK_HEALTH: "1"
        run: mkosi --image-version=2 --force build
      - name: Stage v2-broken split artifacts
        run: |
          mkdir -p update-served-broken
          cp -L mkosi.output/astromesh-os-phase0_2.root-x86-64.raw update-served-broken/
          cp -L mkosi.output/astromesh-os-phase0_2.root-x86-64-verity.raw update-served-broken/
          cp -L mkosi.output/astromesh-os-phase0_2.efi update-served-broken/
          echo "=== broken v2 ==="; ls -la update-served-broken
      - uses: actions/upload-artifact@v4
        with:
          name: phase2b-v2-broken
          path: update-served-broken/*
```

> The broken v2 build runs after the good v2 staging so it overwrites `mkosi.output`
> last; the good v2 artifacts were already copied to `update-served/` before this.

- [ ] **Step 2: Add the `rollback-gate` job**

After the existing `update-gate` job, add:

```yaml
  rollback-gate:
    needs: build-images
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: phase2b-v1
          path: image
      - uses: actions/download-artifact@v4
        with:
          name: phase2b-v2-broken
          path: update-served
      - name: Install QEMU + OVMF
        run: sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils ovmf curl
      - name: Enable KVM access
        run: sudo chmod 666 /dev/kvm 2>/dev/null || echo "no kvm; TCG fallback"
      - name: Serve unhealthy v2 over HTTP (10.0.2.2:8088 from the guest)
        run: |
          cd update-served
          echo "2" > LATEST
          nohup python3 -m http.server 8088 >/tmp/http.log 2>&1 &
          sleep 2 && curl -sf http://127.0.0.1:8088/LATEST
      - name: Convert v1 to qcow2
        run: qemu-img convert -O qcow2 image/v1.raw v1.qcow2
      - name: Run A/B rollback gate
        run: bash tests/boot/rollback-and-assert.sh v1.qcow2
```

- [ ] **Step 3: Validate workflow YAML**

Run: `wsl -d Debian -- python3 -c "import yaml; yaml.safe_load(open('.github/workflows/phase2b-update.yml')); print('yaml OK')"`
Expected: `yaml OK`

- [ ] **Step 4: Commit + push (triggers CI)**

```bash
git add .github/workflows/phase2b-update.yml
git commit -m "ci(phase2b-rollback): rollback gate (unhealthy v2 → back to v1)"
git push -u origin feat/phase2b-rollback
```

> Note: `phase2b-update.yml` currently triggers `on: push: branches: [feat/phase2b]`
> (deleted) + `workflow_dispatch`. Add `feat/phase2b-rollback` to the push branches in
> the same edit, or trigger the run with `gh workflow run phase2b-update.yml --ref feat/phase2b-rollback`.

- [ ] **Step 5: Confirm CI green**

Watch the run; expected: `build-deb`, `build-images`, `update-gate`, `rollback-gate` all success, with `[rollback] ROLLBACK GATE PASSED` in the rollback-gate log.

---

## Done criteria

- Local `dev-loop.sh rollback` prints `ROLLBACK GATE PASSED`.
- CI `phase2b-update.yml` green including the new `rollback-gate`.
- The existing `update-gate` (healthy v2 → stays on v2) still passes — i.e. the
  `+tries`/bless changes did not break the happy path.
- STATUS doc (`docs/superpowers/2026-06-06-phase2b-update-STATUS.md`) updated to note
  2b-rollback done, with the run reference.
