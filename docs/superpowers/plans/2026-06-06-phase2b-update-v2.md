# astromesh-os Fase 2b-update v2 (updater A/B propio) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reemplazar `systemd-sysupdate` por un updater A/B propio en bash que detecta el slot inactivo desde el verity activo, descarga v2, lo escribe con `dd`, instala el UKI v2 y reinicia — y probarlo con el harness multi-boot (v1 → v2).

**Architecture:** Sobre `feat/phase2b` (que tiene el layout A/B, split artifacts, UKI Type 2 y el harness, todo de la rama). Se revierte la maquinaria de sysupdate (transfers, autoupdate, labels de slot que rompían el boot verity, paquete systemd-container) y se agrega un único script `astromesh-update.sh` + su service. Control total: `curl` + `dd` + `cp` + `reboot`, sin SHA256SUMS/GPG/MatchPattern.

**Tech Stack:** bash, util-linux (lsblk/blkid), dm-verity, systemd-boot/bootctl, dd, QEMU/OVMF, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-06-06-phase2b-update-v2-design.md`

**Restricción de entorno:** host Windows; build/boot reales en CI Linux. Verificaciones host-runnable: `bash -n`, `python -c configparser/yaml`. El update real corre en el harness multi-boot (Task 5 = loop de CI).

---

## File Structure

| Archivo | Responsabilidad |
|---------|-----------------|
| `phase2b/astromesh-update.sh` | Updater A/B propio (detecta slot inactivo, dd, instala UKI, reboot). |
| `phase2b/astromesh-update.service` | Oneshot que corre el updater al boot. |
| `mkosi.postinst.chroot` | Instalar el updater; quitar la instalación de sysupdate/autoupdate. |
| `mkosi.repart/{10-root,20-root-verity}.conf` | Quitar los `Label=` de slot (rompían el boot verity). |
| `mkosi.conf` | Quitar `systemd-container`. |
| `.github/workflows/phase2b-update.yml` | Servir `LATEST` + artefactos; quitar `SHA256SUMS`. |
| (borrar) `phase2b/sysupdate.d/`, `phase2b/autoupdate.{sh,service}` | Maquinaria de sysupdate. |

> El layout A/B, `SplitArtifacts`, `UnifiedKernelImages`, `version-marker` y `tests/boot/update-and-assert.sh` se conservan tal cual.

---

## Task 1: Revertir la maquinaria de sysupdate

**Files:**
- Delete: `phase2b/sysupdate.d/10-uki.transfer`, `20-root.transfer`, `30-verity.transfer`, `phase2b/autoupdate.sh`, `phase2b/autoupdate.service`
- Modify: `mkosi.repart/10-root.conf`, `mkosi.repart/20-root-verity.conf`, `mkosi.conf`, `mkosi.postinst.chroot`

- [ ] **Step 1: Borrar los archivos de sysupdate**

```bash
git rm phase2b/sysupdate.d/10-uki.transfer phase2b/sysupdate.d/20-root.transfer phase2b/sysupdate.d/30-verity.transfer phase2b/autoupdate.sh phase2b/autoupdate.service
rmdir phase2b/sysupdate.d 2>/dev/null || true
```

- [ ] **Step 2: Quitar el label de slot en `10-root.conf`**

Eliminar de `mkosi.repart/10-root.conf` exactamente estas líneas (las 2 de comentario + `Label=root-1`):

```
# Versioned label (slot A = version 1) so systemd-sysupdate's MatchPattern=root-@v
# recognizes this as an installed instance and the _empty B slot as the spare.
Label=root-1
```

- [ ] **Step 3: Quitar el label de slot en `20-root-verity.conf`**

Eliminar de `mkosi.repart/20-root-verity.conf` la línea:

```
Label=root-verity-1
```

- [ ] **Step 4: Quitar `systemd-container` de `mkosi.conf`**

Eliminar la línea `systemd-container` del bloque `Packages=` de `mkosi.conf`.

- [ ] **Step 5: Limpiar el postinst**

En `mkosi.postinst.chroot`, eliminar el bloque de instalación de las reglas sysupdate y el bloque de instalación del autoupdate (las líneas que hacen `install ... /usr/lib/sysupdate.d/...`, `install ... autoupdate.sh`, `install ... autoupdate.service`, `systemctl enable autoupdate.service`, y el `install -d /usr/lib/sysupdate.d`). Conservar el bloque del `version-marker` y el `build-version`.

- [ ] **Step 6: Verificar**

Run:
```bash
bash -n mkosi.postinst.chroot && echo "postinst OK"
grep -rq 'sysupdate\|autoupdate' mkosi.postinst.chroot && echo "STILL PRESENT (bad)" || echo "sysupdate refs gone OK"
grep -q 'systemd-container' mkosi.conf && echo "STILL PRESENT (bad)" || echo "systemd-container gone OK"
grep -q 'Label=root' mkosi.repart/10-root.conf mkosi.repart/20-root-verity.conf && echo "LABEL PRESENT (bad)" || echo "labels gone OK"
```
Expected: `postinst OK`, `sysupdate refs gone OK`, `systemd-container gone OK`, `labels gone OK`

- [ ] **Step 7: Commit**

```bash
git update-index --chmod=+x mkosi.postinst.chroot
git add -A
git commit -m "revert(phase2b): remove systemd-sysupdate machinery and slot labels"
```

---

## Task 2: El updater A/B propio

**Files:**
- Create: `phase2b/astromesh-update.sh`

- [ ] **Step 1: Crear `phase2b/astromesh-update.sh`**

```bash
#!/usr/bin/env bash
# A/B updater: download the newest version's split artifacts, write them to the
# INACTIVE root+verity slots, install the new UKI, and reboot into it. No-op (no
# reboot) when the source is unreachable or already on the newest version.
set -uo pipefail

SRC="http://10.0.2.2:8088"
log() { echo "[update] $*"; }

# 1. Newest available version vs running version.
latest=$(curl -fsS "${SRC}/LATEST" 2>/dev/null | tr -dc '0-9')
if [ -z "${latest}" ]; then log "source unreachable / no LATEST; no-op"; exit 0; fi
running=$(tr -dc '0-9' < /usr/lib/astromesh-os/build-version 2>/dev/null)
running=${running:-0}
log "running=${running} latest=${latest}"
if [ "${latest}" -le "${running}" ]; then log "already up to date; no-op"; exit 0; fi

# 2. Active backing partitions of the verity root (data + hash), then pick the
#    INACTIVE partition of each GPT type.
dm=$(basename "$(readlink -f /dev/mapper/root)")
active=""
for s in /sys/block/"${dm}"/slaves/*; do active="${active} /dev/$(basename "${s}")"; done
log "active backing:${active}"

ROOT_TYPE="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
VERITY_TYPE="2c7357ed-ebd2-46d9-aec1-23d437ec2bf5"

inactive_of() {
    local want="$1" path parttype a
    while read -r path parttype; do
        [ "${parttype}" = "${want}" ] || continue
        for a in ${active}; do [ "${path}" = "${a}" ] && continue 2; done
        echo "${path}"; return 0
    done < <(lsblk -b -ln -o PATH,PARTTYPE)
    return 1
}

inactive_root=$(inactive_of "${ROOT_TYPE}")  || { log "FAIL: no inactive root slot"; exit 1; }
inactive_verity=$(inactive_of "${VERITY_TYPE}") || { log "FAIL: no inactive verity slot"; exit 1; }
log "inactive root=${inactive_root} verity=${inactive_verity}"

# 3. Download v_latest split artifacts to tmpfs.
base="astromesh-os-phase0_${latest}"
curl -fsS "${SRC}/${base}.root-x86-64.raw"        -o /run/au-root.raw   || { log "FAIL: download root";   exit 1; }
curl -fsS "${SRC}/${base}.root-x86-64-verity.raw" -o /run/au-verity.raw || { log "FAIL: download verity"; exit 1; }
curl -fsS "${SRC}/${base}.efi"                    -o /run/au-uki.efi    || { log "FAIL: download uki";    exit 1; }

# 4. Write to the inactive slots.
log "writing root image -> ${inactive_root}"
dd if=/run/au-root.raw   of="${inactive_root}"   bs=4M conv=fsync status=none || { log "FAIL: dd root";   exit 1; }
log "writing verity image -> ${inactive_verity}"
dd if=/run/au-verity.raw of="${inactive_verity}" bs=4M conv=fsync status=none || { log "FAIL: dd verity"; exit 1; }

# 5. Install the new UKI into the ESP (its embedded version makes systemd-boot pick it).
esp=$(bootctl --print-esp-path 2>/dev/null || echo /boot)
install -D -m 0644 /run/au-uki.efi "${esp}/EFI/Linux/${base}.efi" || { log "FAIL: install uki"; exit 1; }
log "installed UKI ${esp}/EFI/Linux/${base}.efi"
sync

# 6. Reboot into the new version.
log "update applied; rebooting into v${latest}"
systemctl reboot
```

- [ ] **Step 2: Verificar la sintaxis**

Run: `bash -n phase2b/astromesh-update.sh && echo "updater OK"`
Expected: `updater OK`

- [ ] **Step 3: Hacer ejecutable y commit**

```bash
chmod +x phase2b/astromesh-update.sh
git update-index --chmod=+x phase2b/astromesh-update.sh
git add phase2b/astromesh-update.sh
git commit -m "feat(phase2b): custom A/B updater (detect inactive slot, dd, install UKI, reboot)"
```

---

## Task 3: Service del updater + instalación

**Files:**
- Create: `phase2b/astromesh-update.service`
- Modify: `mkosi.postinst.chroot`

- [ ] **Step 1: Crear `phase2b/astromesh-update.service`**

```ini
[Unit]
Description=Astromesh OS A/B updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/astromesh-os/astromesh-update.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Instalar + habilitar en el postinst**

En `mkosi.postinst.chroot`, después del bloque del `version-marker` (donde se hace `systemctl enable version-marker.service`), agregar:

```bash
# Fase 2b: custom A/B updater.
install -m 0755 "${SRC}/phase2b/astromesh-update.sh" /usr/lib/astromesh-os/astromesh-update.sh
install -m 0644 "${SRC}/phase2b/astromesh-update.service" /etc/systemd/system/astromesh-update.service
systemctl enable astromesh-update.service
```

- [ ] **Step 3: Verificar**

Run:
```bash
bash -n mkosi.postinst.chroot && echo "postinst OK"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('phase2b/astromesh-update.service'); assert c['Service']['Type']=='oneshot'; print('service OK')"
grep -q 'astromesh-update.service' mkosi.postinst.chroot && echo "install OK"
```
Expected: `postinst OK`, `service OK`, `install OK`

- [ ] **Step 4: Commit**

```bash
git update-index --chmod=+x mkosi.postinst.chroot
git add phase2b/astromesh-update.service mkosi.postinst.chroot
git commit -m "feat(phase2b): install+enable the A/B updater service"
```

---

## Task 4: Workflow — servir `LATEST`, quitar `SHA256SUMS`

**Files:**
- Modify: `.github/workflows/phase2b-update.yml`

- [ ] **Step 1: Quitar la generación de `SHA256SUMS` y servir `LATEST`**

En `.github/workflows/phase2b-update.yml`, en el step "Serve v2 artifacts over HTTP", reemplazar el bloque que genera `SHA256SUMS` por uno que escribe `LATEST`. El step `run:` debe quedar:

```yaml
        run: |
          cd update-served
          # The custom updater reads the newest version from a LATEST file.
          echo "2" > LATEST
          echo "=== served ==="; ls -la
          nohup python3 -m http.server 8088 >/tmp/http.log 2>&1 &
          sleep 2 && curl -sf http://127.0.0.1:8088/LATEST
```

- [ ] **Step 2: Confirmar que el staging sirve el UKI bare + root + verity**

Verificar que el step "Stage v2 split artifacts for sysupdate" copia a `update-served/`: `astromesh-os-phase0_2.root-x86-64.raw`, `…-verity.raw`, y `astromesh-os-phase0_2.efi`. (Ya quedó así en `feat/phase2b`.) Si no, ajustarlo a:

```yaml
        run: |
          mkdir -p update-served
          cp -L mkosi.output/astromesh-os-phase0_2.root-x86-64.raw update-served/
          cp -L mkosi.output/astromesh-os-phase0_2.root-x86-64-verity.raw update-served/
          cp -L mkosi.output/astromesh-os-phase0_2.efi update-served/
          echo "=== served ==="; ls -la update-served
```

- [ ] **Step 3: Validar el YAML**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/phase2b-update.yml')); print('workflow OK')"`
Expected: `workflow OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/phase2b-update.yml
git commit -m "ci(phase2b): serve LATEST for the custom updater; drop SHA256SUMS"
```

---

## Task 5: Puesta en verde + iteración (CI)

**Files:** (ninguno nuevo — loop de CI con el harness multi-boot)

- [ ] **Step 1: Pushear y observar `phase2b-update` + `phase0-ci`**

Run: `git push origin feat/phase2b`, observar ambos workflows.
Expected: `phase0-ci` verde (v1 bootea con labels revertidos → boot verity sano). `phase2b-update`: build v1+v2, sirve v2, el updater corre.

- [ ] **Step 2: Diagnosticar con la consola**

El harness vuelca `qemu-console.log`. Buscar las líneas `[update]` (del updater) y `ASTROMESH_BUILD`:
- **`source unreachable`**: el guest no alcanza `10.0.2.2:8088` → revisar el http.server / red.
- **`no inactive root/verity slot`**: la detección de slot falló → revisar `lsblk -b -ln -o PATH,PARTTYPE` en el guest (agregar un `lsblk` de debug al updater si hace falta) y los GPT type UUIDs.
- **`dd` falla / tamaños**: revisar que la `.raw` calce en la partición inactiva.
- **No bootea v2**: tras el reboot, systemd-boot debe elegir el UKI v2 (versión 2). Si bootea v1 de nuevo, revisar el nombre/versión del UKI instalado y el orden de systemd-boot.
Commit cada ajuste, re-pushear, repetir.

- [ ] **Step 3: Confirmar el criterio de salida**

Expected (spec §6):
- `phase2b-update` verde: `ASTROMESH_BUILD=1` → updater escribe v2 al slot inactivo + UKI → reboot → `ASTROMESH_BUILD=2` + health 200.
- `phase0-ci` verde.

- [ ] **Step 4: Cerrar 2b-update**

Tildar la definición de hecho en `docs/superpowers/specs/2026-06-06-phase2b-update-v2-design.md` (§6) con el run de referencia, y commitear. Siguiente ciclo: **2b-rollback**.

---

## Notas de cobertura del spec (self-review)

- §2 reusar/revertir → Task 1 (revert) + se conservan layout/SplitArtifacts/UKI/marcador/harness.
- §3.1 updater (6 pasos: versión, detección de slot, descarga, dd, UKI, reboot) → Task 2. §3.2 service → Task 3. §3.3 instalación → Tasks 1 (limpiar) + 3 (instalar).
- §4 workflow (LATEST, sin SHA256SUMS) → Task 4. §6 gate → Task 5.
- §5 riesgos R1–R5 (detección de slot, dd, orden de UKI, ESP rw, loop) → Task 5 (loop con consola) + el check de versión anti-loop en el updater (Task 2).
