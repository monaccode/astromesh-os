# astromesh-os Fase 2b-update (A/B + systemd-sysupdate) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dar a la imagen inmutable de Fase 2a updates A/B atómicos con `systemd-sysupdate`: dos slots root(verity), artefactos versionados, y un harness multi-boot que prueba que sysupdate aplica v2 al slot inactivo y el sistema bootea v2.

**Architecture:** Sobre el verity de Fase 2a (en `main`, branch `feat/phase2b`). `mkosi.repart` gana un segundo slot root+verity (`_empty`). mkosi emite artefactos **split** versionados (root.raw + verity.raw + UKI) vía `--image-version` y `SplitArtifacts`. `systemd-sysupdate` (`.transfer` horneados) descarga la versión nueva desde un HTTP local (`10.0.2.2` en QEMU user-net) al slot inactivo; un `autoupdate.service` la aplica y reinicia. Un oneshot loguea `ASTROMESH_BUILD=<ver>` para que el harness multi-boot asevere `1 → 2`.

**Tech Stack:** mkosi 25.3, systemd-sysupdate, systemd-boot (UKI Type 2), dm-verity, QEMU/OVMF, python http.server, GitHub Actions, bash.

**Spec:** `docs/superpowers/specs/2026-06-05-phase2b-update-design.md`

**Restricción de entorno:** host Windows; build/boot/sysupdate reales en CI Linux. Verificaciones host-runnable: `bash -n`, `python -c configparser/yaml`. Los knobs de `SplitArtifacts`/`MatchPattern` de sysupdate son **version-sensibles** (P2b-1/2) → la Task 7 es el loop de CI donde se ajustan, como la verity de Fase 2a.

---

## File Structure

| Archivo | Responsabilidad |
|---------|-----------------|
| `mkosi.conf` | `SplitArtifacts=` (emitir root/verity/UKI por versión). |
| `mkosi.repart/40-root-b.conf` | Segundo slot root (`_empty`, sin CopyFiles). |
| `mkosi.repart/50-verity-b.conf` | Segundo slot verity (`_empty`). |
| `phase2b/sysupdate.d/{10-uki,20-root,30-verity}.transfer` | Reglas de sysupdate (source HTTP → slot inactivo). |
| `phase2b/version-marker.sh` + `.service` | Loguea `ASTROMESH_BUILD=<ver>` a consola. |
| `phase2b/autoupdate.sh` + `.service` | Corre sysupdate; reinicia si aplicó update; no-op si la fuente no responde. |
| `mkosi.postinst.chroot` | Hornea `build-version`, instala sysupdate.d + los dos services. |
| `tests/boot/update-and-assert.sh` | Harness multi-boot (v1 → update → v2). |
| `.github/workflows/phase2b-update.yml` | Build v1+v2, sirve v2 por HTTP, corre el harness. |

> `phase0-ci.yml` + `tests/boot/run-and-assert.sh` (boot único) **no se tocan** y siguen siendo la regresión.

---

## Task 1: Artefactos split + marcador de versión

**Files:**
- Modify: `mkosi.conf`
- Modify: `mkosi.postinst.chroot`
- Create: `phase2b/version-marker.sh`
- Create: `phase2b/version-marker.service`

mkosi expone `$IMAGE_VERSION` a los scripts (seteado con `mkosi --image-version=N`). Lo horneamos en un archivo y lo emitimos a consola; y pedimos a mkosi los artefactos split para sysupdate.

- [ ] **Step 1: Habilitar SplitArtifacts en `mkosi.conf`**

En `mkosi.conf`, en la sección `[Output]` (después de `ImageId=astromesh-os-phase0`), agregar:

```ini
SplitArtifacts=uki,partitions
```

- [ ] **Step 2: Crear `phase2b/version-marker.sh`**

```bash
#!/usr/bin/env bash
# Logs the baked image version to the console so the multi-boot harness can tell
# which version is running (e.g. ASTROMESH_BUILD=1 before update, =2 after).
set -uo pipefail
ver="$(cat /usr/lib/astromesh-os/build-version 2>/dev/null || echo unknown)"
echo "ASTROMESH_BUILD=${ver}"
```

- [ ] **Step 3: Crear `phase2b/version-marker.service`**

```ini
[Unit]
Description=Astromesh OS build version marker
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/lib/astromesh-os/version-marker.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Hornear la versión + instalar el marcador en el postinst**

En `mkosi.postinst.chroot`, inmediatamente después de la línea `install -d /usr/lib/astromesh-os` (sección 9, ya existente), agregar:

```bash
# Fase 2b: bake the image version and a console version marker for the A/B test.
echo "${IMAGE_VERSION:-1}" > /usr/lib/astromesh-os/build-version
install -m 0755 "${SRC}/phase2b/version-marker.sh" /usr/lib/astromesh-os/version-marker.sh
install -m 0644 "${SRC}/phase2b/version-marker.service" /etc/systemd/system/version-marker.service
systemctl enable version-marker.service
```

- [ ] **Step 5: Verificar**

Run:
```bash
bash -n phase2b/version-marker.sh && echo "marker OK"
bash -n mkosi.postinst.chroot && echo "postinst OK"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('mkosi.conf'); assert 'SplitArtifacts' in c['Output']; print('mkosi.conf OK')"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('phase2b/version-marker.service'); assert c['Service']['Type']=='oneshot'; print('service OK')"
```
Expected: `marker OK`, `postinst OK`, `mkosi.conf OK`, `service OK`

- [ ] **Step 6: Commit**

```bash
chmod +x phase2b/version-marker.sh
git update-index --chmod=+x phase2b/version-marker.sh mkosi.postinst.chroot
git add mkosi.conf phase2b/version-marker.sh phase2b/version-marker.service mkosi.postinst.chroot
git commit -m "feat(phase2b): split artifacts + console version marker"
```

---

## Task 2: Segundo slot A/B (`mkosi.repart`)

**Files:**
- Create: `mkosi.repart/40-root-b.conf`
- Create: `mkosi.repart/50-verity-b.conf`

El slot B va vacío con label `_empty` (la convención de systemd para slots libres que sysupdate llena). El slot A (10-root/20-root-verity de Fase 2a) queda como está (poblado v1).

- [ ] **Step 1: Crear `mkosi.repart/40-root-b.conf`**

```ini
[Partition]
Type=root
Label=_empty
ReadOnly=yes
SizeMinBytes=512M
```

- [ ] **Step 2: Crear `mkosi.repart/50-verity-b.conf`**

```ini
[Partition]
Type=root-verity
Label=_empty
SizeMinBytes=32M
```

- [ ] **Step 3: Verificar**

Run:
```bash
for f in mkosi.repart/40-root-b.conf mkosi.repart/50-verity-b.conf; do python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('$f'); assert c['Partition']['Label']=='_empty'; print('$f OK')"; done
```
Expected: ambas líneas terminan en `OK`.

- [ ] **Step 4: Commit**

```bash
git add mkosi.repart/40-root-b.conf mkosi.repart/50-verity-b.conf
git commit -m "feat(phase2b): add empty B slot (root + verity) for A/B updates"
```

---

## Task 3: Reglas de `systemd-sysupdate`

**Files:**
- Create: `phase2b/sysupdate.d/10-uki.transfer`
- Create: `phase2b/sysupdate.d/20-root.transfer`
- Create: `phase2b/sysupdate.d/30-verity.transfer`
- Modify: `mkosi.postinst.chroot`

Cada `.transfer` define de dónde baja (HTTP local `10.0.2.2:8088`) y a dónde escribe (ESP / slot inactivo). El puerto `8088` lo sirve el harness (Task 6). Los `MatchPattern` exactos dependen de cómo nombre mkosi los artefactos split (P2b-1) → la Task 7 los ajusta.

- [ ] **Step 1: Crear `phase2b/sysupdate.d/10-uki.transfer`**

```ini
[Source]
Type=url-file
Path=http://10.0.2.2:8088/
MatchPattern=astromesh-os-phase0_@v.efi

[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot
MatchPattern=astromesh-os-phase0_@v.efi
InstancesMax=2
```

- [ ] **Step 2: Crear `phase2b/sysupdate.d/20-root.transfer`**

```ini
[Source]
Type=url-file
Path=http://10.0.2.2:8088/
MatchPattern=astromesh-os-phase0_@v.root-x86-64.raw

[Target]
Type=partition
MatchPattern=root-@v
Type=root
InstancesMax=2
ReadOnly=yes
```

- [ ] **Step 3: Crear `phase2b/sysupdate.d/30-verity.transfer`**

```ini
[Source]
Type=url-file
Path=http://10.0.2.2:8088/
MatchPattern=astromesh-os-phase0_@v.root-x86-64-verity.raw

[Target]
Type=partition
MatchPattern=root-verity-@v
Type=root-verity
InstancesMax=2
ReadOnly=yes
```

- [ ] **Step 4: Instalar las reglas en el postinst**

En `mkosi.postinst.chroot`, después del bloque del marcador de versión (Task 1 Step 4), agregar:

```bash
# Fase 2b: systemd-sysupdate A/B transfer rules.
install -d /usr/lib/sysupdate.d
install -m 0644 "${SRC}/phase2b/sysupdate.d/10-uki.transfer" /usr/lib/sysupdate.d/10-uki.transfer
install -m 0644 "${SRC}/phase2b/sysupdate.d/20-root.transfer" /usr/lib/sysupdate.d/20-root.transfer
install -m 0644 "${SRC}/phase2b/sysupdate.d/30-verity.transfer" /usr/lib/sysupdate.d/30-verity.transfer
```

- [ ] **Step 5: Verificar**

Run:
```bash
for f in phase2b/sysupdate.d/*.transfer; do python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('$f'); assert 'Source' in c and 'Target' in c; print('$f OK')"; done
bash -n mkosi.postinst.chroot && echo "postinst OK"
```
Expected: tres `OK` + `postinst OK`.

- [ ] **Step 6: Commit**

```bash
git update-index --chmod=+x mkosi.postinst.chroot
git add phase2b/sysupdate.d mkosi.postinst.chroot
git commit -m "feat(phase2b): systemd-sysupdate transfer rules (uki/root/verity)"
```

---

## Task 4: Servicio de auto-update

**Files:**
- Create: `phase2b/autoupdate.sh`
- Create: `phase2b/autoupdate.service`
- Modify: `mkosi.postinst.chroot`

- [ ] **Step 1: Crear `phase2b/autoupdate.sh`**

```bash
#!/usr/bin/env bash
# Applies an available A/B update and reboots into it. Reboots ONLY if a newer
# version was actually installed — so it is a no-op (no reboot) when the source is
# unreachable (phase0-ci has no server) OR when already running the newest version
# (prevents a reboot loop once booted into v2).
set -uo pipefail

out="$(systemd-sysupdate update 2>&1)"; rc=$?
echo "[autoupdate] (rc=${rc}) ${out}"

if [ "${rc}" -eq 0 ] \
   && echo "${out}" | grep -qiE 'installing|installed|acquiring' \
   && ! echo "${out}" | grep -qi 'already'; then
    echo "[autoupdate] new version installed; rebooting"
    systemctl reboot
else
    echo "[autoupdate] no reboot (no newer version or source unreachable)"
fi
```

- [ ] **Step 2: Crear `phase2b/autoupdate.service`**

```ini
[Unit]
Description=Astromesh OS A/B auto-update
After=astromeshd.service network-online.target version-marker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/astromesh-os/autoupdate.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Instalar + habilitar en el postinst**

En `mkosi.postinst.chroot`, después del bloque de las reglas sysupdate (Task 3 Step 4), agregar:

```bash
# Fase 2b: auto-update trigger (no-op when the source is unreachable).
install -m 0755 "${SRC}/phase2b/autoupdate.sh" /usr/lib/astromesh-os/autoupdate.sh
install -m 0644 "${SRC}/phase2b/autoupdate.service" /etc/systemd/system/autoupdate.service
systemctl enable autoupdate.service
```

- [ ] **Step 4: Verificar**

Run:
```bash
bash -n phase2b/autoupdate.sh && echo "autoupdate OK"
bash -n mkosi.postinst.chroot && echo "postinst OK"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('phase2b/autoupdate.service'); assert c['Service']['Type']=='oneshot'; print('service OK')"
```
Expected: `autoupdate OK`, `postinst OK`, `service OK`

- [ ] **Step 5: Commit**

```bash
chmod +x phase2b/autoupdate.sh
git update-index --chmod=+x phase2b/autoupdate.sh mkosi.postinst.chroot
git add phase2b/autoupdate.sh phase2b/autoupdate.service mkosi.postinst.chroot
git commit -m "feat(phase2b): auto-update service (applies update, reboots; no-op offline)"
```

---

## Task 5: Harness multi-boot

**Files:**
- Create: `tests/boot/update-and-assert.sh`

Arranca v1 en QEMU persistente (sin `-no-reboot`), asevera `ASTROMESH_BUILD=1`, deja que el guest se auto-actualice y reinicie, y asevera `ASTROMESH_BUILD=2` tras el reboot.

- [ ] **Step 1: Crear `tests/boot/update-and-assert.sh`**

```bash
#!/usr/bin/env bash
# A/B update test: boot v1, let the guest auto-update to v2 (served over HTTP on
# the host at 10.0.2.2:8088 via SLIRP), and assert it reboots into v2.
# Usage: tests/boot/update-and-assert.sh <v1-disk-image>
set -euo pipefail

IMAGE="${1:?usage: update-and-assert.sh <disk-image>}"
PORT=8000
TIMEOUT=300

qemu-img resize "${IMAGE}" +4G >/dev/null

KVM_FLAG=""
if [ -w /dev/kvm ]; then KVM_FLAG="-enable-kvm"; fi

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    if [ -f "$c" ]; then OVMF_CODE="$c"; break; fi
done
OVMF_VARS_SRC=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    if [ -f "$v" ]; then OVMF_VARS_SRC="$v"; break; fi
done
[ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS_SRC}" ] || { echo "[update] FAIL: OVMF not found"; exit 1; }
cp "${OVMF_VARS_SRC}" ovmf_vars.fd

echo "[update] starting QEMU (persistent, reboots allowed)"
qemu-system-x86_64 \
    ${KVM_FLAG} -machine q35 -m 2048 -smp 2 -nographic \
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

echo "[update] waiting for v1 health"
wait_health 180 || { echo "[update] FAIL: v1 never came up"; tail -n 120 qemu-console.log; exit 1; }
if grep -q "ASTROMESH_BUILD=1" qemu-console.log; then
    echo "[update] PASS: booted v1"
else
    echo "[update] FAIL: v1 marker not found"; grep -i ASTROMESH_BUILD qemu-console.log || true; exit 1
fi

echo "[update] waiting for auto-update + reboot into v2 (up to ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
until grep -q "ASTROMESH_BUILD=2" qemu-console.log; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[update] FAIL: never booted v2"
        echo "----- autoupdate/sysupdate lines -----"; grep -iE 'autoupdate|sysupdate|ASTROMESH_BUILD' qemu-console.log || true
        echo "----- console tail -----"; tail -n 150 qemu-console.log || true
        exit 1
    fi
    sleep 5
done
echo "[update] PASS: booted v2"

wait_health 120 || { echo "[update] FAIL: v2 health did not come up"; exit 1; }
echo "[update] PASS: v2 /v1/health is 200"
echo "[update] UPDATE GATE PASSED"
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n tests/boot/update-and-assert.sh && echo "harness OK"`
Expected: `harness OK`

- [ ] **Step 3: Hacer ejecutable y commit**

```bash
chmod +x tests/boot/update-and-assert.sh
git update-index --chmod=+x tests/boot/update-and-assert.sh
git add tests/boot/update-and-assert.sh
git commit -m "test(phase2b): multi-boot A/B update harness (v1 -> v2)"
```

---

## Task 6: Workflow `phase2b-update.yml`

**Files:**
- Create: `.github/workflows/phase2b-update.yml`

Construye v1 (imagen completa) y v2 (artefactos split), sirve v2 por HTTP, y corre el harness. El build reusa el patrón de `phase0-ci` (contenedor trixie privilegiado para mkosi).

- [ ] **Step 1: Crear el workflow**

```yaml
name: phase2b-update

on:
  push:
    branches: [feat/phase2b]
  workflow_dispatch:

jobs:
  build-deb:
    runs-on: ubuntu-24.04
    container: debian:trixie
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - id: pin
        run: |
          . runtime.pin
          echo "ref=${ASTROMESH_REF}" >> "$GITHUB_OUTPUT"
      - uses: actions/checkout@v4
        with:
          repository: monaccode/astromesh
          ref: ${{ steps.pin.outputs.ref }}
          path: _runtime
      - name: Install build deps
        run: |
          apt-get update
          apt-get install -y python3 python3-venv python3-pip git curl ca-certificates build-essential
      - name: Install nfpm
        run: |
          url=$(curl -sfL https://api.github.com/repos/goreleaser/nfpm/releases/latest \
            | python3 -c "import sys,json; a=json.load(sys.stdin)['assets']; print(next(x['browser_download_url'] for x in a if x['name'].endswith('_amd64.deb')))")
          curl -sfL "$url" -o nfpm.deb
          apt-get install -y ./nfpm.deb
      - name: Build .deb
        working-directory: _runtime/astromesh-node
        run: bash packaging/build-deb.sh
      - run: mkdir -p dist && cp _runtime/astromesh-node/dist/astromesh-node_*_amd64.deb dist/
      - uses: actions/upload-artifact@v4
        with:
          name: astromesh-deb
          path: dist/*.deb

  build-images:
    needs: build-deb
    runs-on: ubuntu-24.04
    container:
      image: debian:trixie
      options: --privileged
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: astromesh-deb
          path: dist
      - name: Install mkosi + image tools
        run: |
          apt-get update
          apt-get install -y mkosi systemd-ukify systemd-boot mtools dosfstools ca-certificates
      - name: Build v1 (full image)
        env:
          PHASE0_MODE: stub
        run: mkosi --image-version=1 build
      - run: mkdir -p out && cp mkosi.output/*.raw out/v1.raw
      - name: Build v2 (split artifacts)
        env:
          PHASE0_MODE: stub
        run: mkosi --image-version=2 --force build
      - name: Stage v2 split artifacts for sysupdate
        run: |
          mkdir -p update-served
          cp mkosi.output/astromesh-os-phase0_2* update-served/ 2>/dev/null || cp mkosi.output/*_2* update-served/
          ls -la update-served
      - uses: actions/upload-artifact@v4
        with:
          name: phase2b-v1
          path: out/v1.raw
      - uses: actions/upload-artifact@v4
        with:
          name: phase2b-v2-served
          path: update-served/*

  update-gate:
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
          name: phase2b-v2-served
          path: update-served
      - name: Install QEMU + OVMF
        run: sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils ovmf curl
      - name: Enable KVM access
        run: sudo chmod 666 /dev/kvm 2>/dev/null || echo "no kvm; TCG fallback"
      - name: Serve v2 artifacts over HTTP (10.0.2.2:8088 from the guest)
        run: |
          cd update-served && nohup python3 -m http.server 8088 >/tmp/http.log 2>&1 &
          sleep 2 && curl -sf http://127.0.0.1:8088/ | head -5
      - name: Convert v1 to qcow2
        run: qemu-img convert -O qcow2 image/v1.raw v1.qcow2
      - name: Run A/B update gate
        run: bash tests/boot/update-and-assert.sh v1.qcow2
```

- [ ] **Step 2: Validar el YAML**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/phase2b-update.yml')); print('workflow OK')"`
Expected: `workflow OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/phase2b-update.yml
git commit -m "ci(phase2b): A/B update workflow (build v1+v2, serve v2, multi-boot test)"
```

---

## Task 7: Puesta en verde + iteración de sysupdate/A-B (CI)

**Files:** (ninguno nuevo — iteración sobre el matching de sysupdate y el multi-boot)

Es el loop más incierto del programa (P2b-1/2). El `phase0-ci` (boot único de v1 sobre el layout A/B) y el `phase2b-update` (multi-boot) corren en paralelo.

- [ ] **Step 1: Pushear y observar ambos workflows**

Run: `git push -u origin feat/phase2b`, luego observar `phase0-ci` (regresión) y `phase2b-update` (gate nuevo).
Expected: `phase0-ci` verde (v1 bootea con el layout A/B). `phase2b-update` probablemente falle primero en el matching de sysupdate.

- [ ] **Step 2: Confirmar los nombres reales de los artefactos split**

Run: `gh run view <phase2b-run> --log | grep -iE 'mkosi.output|\.raw|\.efi|astromesh-os-phase0_2'`
Expected: los nombres exactos que mkosi 25.3 emitió para v2 (root/verity/UKI). Ajustar los `MatchPattern` de `phase2b/sysupdate.d/*.transfer` y el `cp` del staging (Task 6) a esos nombres reales.

- [ ] **Step 3: Diagnosticar el matching de sysupdate**

Si el guest no actualiza, leer `qemu-console.log` (el harness vuelca las líneas `autoupdate|sysupdate`):
- **"no update applied"**: sysupdate no ve v2 → patrón/URL mal. Confirmar que el guest alcanza `http://10.0.2.2:8088/` y que `systemd-sysupdate list` (agregar al `autoupdate.sh` un `list` a consola si hace falta) muestra v2.
- **Target partition no matchea**: el `MatchPattern=root-@v` vs los labels reales de los slots (`_empty`/`root`). Ajustar a la convención real de sysupdate para slots A/B.
- **UKI no instalado**: revisar `PathRelativeTo`/`Path` del `10-uki.transfer` contra la ubicación real del ESP/`/EFI/Linux`.
Commit cada ajuste, re-pushear, repetir.

- [ ] **Step 4: Confirmar el criterio de salida**

Expected (spec §5):
- `phase2b-update` verde: `ASTROMESH_BUILD=1` → update → reboot → `ASTROMESH_BUILD=2` + health 200.
- `phase0-ci` verde sobre el layout A/B.

- [ ] **Step 5: Cerrar 2b-update**

Tildar la definición de hecho en `docs/superpowers/specs/2026-06-05-phase2b-update-design.md` (§5) con el run de referencia, y commitear. Siguiente ciclo: **2b-rollback** (boot-assessment / boot-counting).

---

## Notas de cobertura del spec (self-review)

- §3.1 layout A/B → Task 2 (`40-root-b`/`50-verity-b`). §3.2 split artifacts/versión → Task 1.
- §3.3 sysupdate `.transfer` → Task 3. §3.4 autoupdate → Task 4. §3.5 marcador de versión → Task 1.
- §3.6 harness multi-boot + workflow → Tasks 5+6. §2/§5 gate (ASTROMESH_BUILD 1→2 + phase0-ci regresión) → Tasks 5+6+7.
- §4 riesgos P2b-1..6 (matching version-sensible, reboot en CI, autoupdate no-op offline) → Task 7 (loop con consola).
