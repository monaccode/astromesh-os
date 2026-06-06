# astromesh-os — Fase 2b-update (v2): updater A/B propio (reemplaza systemd-sysupdate) (spec)

> **Estado:** Diseño aprobado (2026-06-06)
> **Sub-proyecto:** B (Inmutabilidad + Updates) — **parte 2b-update**, segundo intento.
> **Reemplaza:** el enfoque con `systemd-sysupdate` ([spec previo](2026-06-05-phase2b-update-design.md)), que se volvió un grind con verity en Debian/mkosi (matching de slots, `SHA256SUMS`/GPG, y los labels de slot rompían el boot verity). El intento queda en el historial de `feat/phase2b`.
> **Depende de:** Fase 2a (imagen verity inmutable, en `main`).

---

## 1. Objetivo y gate

**Objetivo:** updates A/B atómicos con un **updater propio en bash** (control total, sin las convenciones opacas de sysupdate): detecta el slot inactivo desde el verity activo, descarga v2, lo escribe con `dd`, instala el UKI v2 y reinicia. El sistema bootea v2.

**Gate de salida (duro):**
1. El harness multi-boot prueba `ASTROMESH_BUILD=1` → update → reboot → **`ASTROMESH_BUILD=2`** (+ `/v1/health` 200 en v2).
2. `phase0-ci` sigue verde (v1 bootea sobre el layout A/B + verity).

**Fuera de alcance:** rollback automático (ciclo 2b-rollback); firma/Secure Boot (Fase 3).

---

## 2. Qué se reusa y qué se reemplaza

**Se reusa (ya funciona en `feat/phase2b`):**
- Layout A/B: `mkosi.repart/{40-root-b,50-verity-b}.conf` (slots `_empty`).
- `SplitArtifacts=uki,partitions` → emite por versión `…_<v>.root-x86-64.raw`, `…_<v>.root-x86-64-verity.raw`, y el UKI `…_<v>.efi`.
- `UnifiedKernelImages=yes` (+ `systemd-boot-efi`): UKI Type 2 en `/EFI/Linux` con roothash + versión embebida → systemd-boot bootea el de mayor versión.
- `version-marker` (loguea `ASTROMESH_BUILD=<v>` a consola).
- Harness multi-boot (`tests/boot/update-and-assert.sh`) + serving HTTP de v2.

**Se revierte/quita (era de sysupdate):**
- Labels `Label=root-1`/`Label=root-verity-1` en `mkosi.repart/{10-root,20-root-verity}.conf` → **volver a los defaults de mkosi** (los labels rompían el boot verity).
- `phase2b/sysupdate.d/*.transfer` (borrar).
- `phase2b/autoupdate.{sh,service}` (sysupdate) → reemplazado por el updater propio.
- Paquete `systemd-container` de `mkosi.conf` (era sólo por el binario `systemd-sysupdate`).
- `SHA256SUMS` y `Verify=` del workflow.

---

## 3. El updater propio

### 3.1 `phase2b/astromesh-update.sh`
Bash, idempotente, no-op si la fuente no responde. Pasos:

1. **Versión disponible:** `curl -fsS http://10.0.2.2:8088/LATEST` → entero (p. ej. `2`). Si falla (fuente inalcanzable) → salir 0 sin reboot. `running=$(cat /usr/lib/astromesh-os/build-version)`. Si `latest <= running` → salir 0 (no-op, evita loop una vez en v2).
2. **Detectar slots inactivos desde el verity activo:**
   - El root activo es `/dev/mapper/root` (verity). Sus backing devices: `/sys/block/<dm>/slaves/` → la **partición de datos activa** (root-data) y la **partición de hash activa** (root-verity).
   - Enumerar todas las particiones por **GPT type**: `lsblk -b -o NAME,PARTTYPE,PATH` (util-linux ya está). Tipo root-x86-64 = `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`; root-x86-64-verity = `2c7357ed-ebd2-46d9-aec1-23d437ec2bf5`.
   - `INACTIVE_ROOT` = la partición de tipo root **distinta** de la data activa. `INACTIVE_VERITY` = la de tipo root-verity **distinta** de la hash activa.
3. **Descargar v2:** `curl -fsS` de `astromesh-os-phase0_<latest>.root-x86-64.raw`, `…-verity.raw`, `…_<latest>.efi` a `/run` (tmpfs).
4. **Escribir al slot inactivo:** `dd if=<root.raw> of=${INACTIVE_ROOT} bs=4M conv=fsync` y lo mismo para verity → `${INACTIVE_VERITY}`.
5. **Instalar el UKI v2:** montar el ESP (o usar el automount `/boot`/`/efi`), copiar el UKI a `/EFI/Linux/astromesh-os-phase0_<latest>.efi`. systemd-boot ordena por versión embebida → bootea v2 (que apunta por roothash al slot inactivo recién escrito).
6. **Reboot:** `systemctl reboot`.

### 3.2 `phase2b/astromesh-update.service`
Oneshot, `After=network-online.target` (sin ciclo de ordenamiento), `WantedBy=multi-user.target`, salida a `journal+console`.

### 3.3 Instalación (`mkosi.postinst.chroot`)
Reemplazar el bloque de instalación de sysupdate/autoupdate por: instalar `astromesh-update.sh` en `/usr/lib/astromesh-os/`, el `.service` en `/etc/systemd/system/`, y `systemctl enable astromesh-update.service`.

---

## 4. Testing y workflow

- **Serving (workflow `phase2b-update.yml`):** servir `astromesh-os-phase0_2.root-x86-64.raw`, `…-verity.raw`, `…_2.efi`, y un archivo `LATEST` con `2`. **Sin** `SHA256SUMS`.
- **Harness (`update-and-assert.sh`, ya existe):** boot v1 (poll `ASTROMESH_BUILD=1`), esperar el reboot a v2, asertar `ASTROMESH_BUILD=2` + health. Sin cambios salvo confirmar timeouts.
- **`phase0-ci`** sigue como regresión (v1 bootea).

---

## 5. Riesgos

| ID | Riesgo | Mitigación |
|----|--------|-----------|
| R1 | **Detección de slot inactivo** incorrecta → escribe el slot activo. | Derivar la data/hash activas de `/sys/block/<dm>/slaves`; elegir las particiones del mismo GPT type que NO son las activas. Loguear a consola qué slots detectó antes de `dd`. El harness (debe bootear v2, no romper v1) es el check. |
| R2 | **`dd` corrompe** o tamaños no calzan. | Las `.raw` split son imágenes de partición del tamaño exacto; `dd ... conv=fsync`. Si el slot inactivo es más chico que la `.raw`, fallar con error claro. |
| R3 | **systemd-boot no elige v2.** | El UKI v2 lleva versión embebida 2 > 1; systemd-boot ordena por versión. Confirmar en consola del segundo boot (`ASTROMESH_BUILD=2`). Si no, revisar el nombre/orden del UKI. |
| R4 | **ESP read-only / no montado** al instalar el UKI. | El ESP se automonta (`/boot` o `/efi`); montarlo rw explícitamente si hace falta. Es FAT (escribible), no parte del root verity. |
| R5 | **Reboot loop.** | El check de versión (`latest <= running` → no-op) corta el loop una vez en v2. |

---

## 6. Criterio de "hecho"

- [ ] `phase2b-update.yml` verde: `ASTROMESH_BUILD=1` → el updater propio escribe v2 al slot inactivo + instala el UKI → reboot → `ASTROMESH_BUILD=2` + health 200.
- [ ] `phase0-ci` verde (v1 bootea sobre el layout A/B; labels revertidos → boot verity sano).
- [ ] El updater es no-op (sin reboot) cuando la fuente no responde o ya está en la última versión.

Cumplido → siguiente ciclo: **2b-rollback** (boot-assessment / boot-counting), que sobre este updater propio es más directo (marcar el slot bueno; si v2 no llega a healthy, volver a bootear el slot anterior).
