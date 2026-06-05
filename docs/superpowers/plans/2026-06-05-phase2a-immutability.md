# astromesh-os Fase 2a (Inmutabilidad: dm-verity + root RO + /var) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hacer la imagen inmutable: root completo bajo dm-verity (read-only, integridad sin firma), escrituras de runtime efímeras vía overlay volátil, y una partición `/var` persistente creada en el primer boot — sin romper el boot-to-agent de Fase 0/1.

**Architecture:** Se construye sobre la imagen mínima de Fase 1 (en `main`, branch `feat/phase2`). Build en contenedor `debian:trixie` privilegiado (mkosi 25.3). `mkosi.repart/` define ESP + root(verity-data) + root-verity(hash); mkosi embebe `roothash=` en el UKI. `systemd.volatile=overlay` da `/etc` efímero (tmpfs sobre el root verity). `systemd-repart` crea `/var` en el primer boot (GPT auto-mount), y tmpfiles recrea los dirs del runtime ahí. Un oneshot asevera la inmutabilidad a consola.

**Tech Stack:** mkosi, systemd-repart, dm-verity, systemd.volatile, systemd-tmpfiles, QEMU/OVMF, GitHub Actions, bash.

**Spec:** `docs/superpowers/specs/2026-06-05-phase2a-immutability-design.md`

**Restricción de entorno:** host Windows; build/boot autoritativos en CI Linux. Verificaciones host-runnable: `bash -n`, `python -c configparser`. El boot/verity reales corren en CI; la verity de mkosi 25.3 puede requerir ajuste de knobs en la primera corrida (riesgo P2-4) — el loop está en la Task 6.

---

## File Structure

| Archivo | Responsabilidad |
|---------|-----------------|
| `mkosi.repart/00-esp.conf` | Partición ESP (UKI). |
| `mkosi.repart/10-root.conf` | Root ext4 con `Verity=data`. |
| `mkosi.repart/20-root-verity.conf` | Partición verity-hash de root. |
| `mkosi.conf` | `KernelCommandLine` += `systemd.volatile=overlay`. |
| `phase2/repart.d/50-var.conf` | Crea/crece `/var` en first-boot (runtime systemd-repart). |
| `phase2/tmpfiles/astromesh-var.conf` | Recrea `/var/lib/astromesh` + logs sobre el `/var` fresco. |
| `phase2/immutability-check.sh` | Chequea root RO + verity + /var writable; loguea marcador. |
| `phase2/immutability-check.service` | Oneshot que corre el check al boot. |
| `mkosi.postinst.chroot` | Instala repart.d, tmpfiles, el check + lo habilita. |
| `tests/boot/run-and-assert.sh` | Resize del disco (espacio para /var) + asevera `IMMUTABILITY OK`. |

> El boot-gate de Fase 0/1 (`phase0-ci.yml` + el harness) sigue siendo el check funcional; se le suma la aserción de inmutabilidad.

---

## Task 1: Particiones verity (build-time)

**Files:**
- Create: `mkosi.repart/00-esp.conf`
- Create: `mkosi.repart/10-root.conf`
- Create: `mkosi.repart/20-root-verity.conf`

Proveer `mkosi.repart/` hace que mkosi use ESTAS particiones (reemplaza su layout default ESP+root). El par `Verity=data`/`Verity=hash` con el mismo `VerityMatchKey` hace que mkosi compute el árbol verity y embeba `roothash=` en el cmdline del UKI.

- [ ] **Step 1: Crear `mkosi.repart/00-esp.conf`**

```ini
[Partition]
Type=esp
Format=vfat
SizeMinBytes=512M
SizeMaxBytes=512M
```

- [ ] **Step 2: Crear `mkosi.repart/10-root.conf`**

```ini
[Partition]
Type=root
Format=ext4
Minimize=best
Verity=data
VerityMatchKey=root
```

- [ ] **Step 3: Crear `mkosi.repart/20-root-verity.conf`**

```ini
[Partition]
Type=root-verity
Verity=hash
VerityMatchKey=root
Minimize=best
```

- [ ] **Step 4: Verificar que los INI parsean**

Run:
```bash
for f in mkosi.repart/*.conf; do python -c "import configparser,sys; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('$f'); assert 'Partition' in c; print('$f OK')"; done
```
Expected: las 3 líneas terminan en `OK`.

- [ ] **Step 5: Commit**

```bash
git add mkosi.repart/
git commit -m "feat(phase2a): verity partition layout (root data + hash)"
```

---

## Task 2: Root genuinamente read-only (sin overlay volátil)

**Files:**
- Modify: `mkosi.conf` (`KernelCommandLine`)

**Decisión:** el root verity se monta **read-only genuino** (rechaza escrituras), NO con `systemd.volatile=overlay` (que volvería todo el root escribible-pero-efímero, contradiciendo "root read-only" y la aserción #1). `/etc` queda stateless vía los fallbacks de systemd a `/run` (machine-id transitorio, resolv, leases).

- [ ] **Step 1: Dejar el cmdline sin overlay volátil**

En `mkosi.conf`, la línea `KernelCommandLine=` debe quedar exactamente (sin `systemd.volatile=overlay`):

```ini
KernelCommandLine=console=ttyS0 systemd.journald.forward_to_console=1
```

- [ ] **Step 2: Verificar**

Run: `python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('mkosi.conf'); cl=c['Content']['KernelCommandLine']; assert 'volatile' not in cl and 'console=ttyS0' in cl; print('cmdline OK')"`
Expected: `cmdline OK`

- [ ] **Step 3: Commit**

```bash
git add mkosi.conf
git commit -m "feat(phase2a): keep root genuinely read-only (no volatile overlay)"
```

---

## Task 3: Partición `/var` persistente (first-boot)

**Files:**
- Create: `phase2/repart.d/50-var.conf`
- Create: `phase2/tmpfiles/astromesh-var.conf`
- Modify: `mkosi.postinst.chroot`

`systemd-repart` corre al boot y aplica `/usr/lib/repart.d/*.conf`; la partición `Type=var` se auto-monta en `/var` vía GPT auto-discovery. tmpfiles recrea los dirs del runtime sobre el `/var` fresco (la partición montada tapa los dirs horneados por el `.deb`).

- [ ] **Step 1: Crear `phase2/repart.d/50-var.conf`**

```ini
[Partition]
Type=var
Format=ext4
SizeMinBytes=128M
GrowFileSystem=yes
```

- [ ] **Step 2: Crear `phase2/tmpfiles/astromesh-var.conf`**

```
d /var/lib/astromesh 0750 astromesh astromesh -
d /var/lib/astromesh/memory 0750 astromesh astromesh -
d /var/lib/astromesh/data 0750 astromesh astromesh -
d /var/log/astromesh 0750 astromesh astromesh -
d /var/log/astromesh/audit 0750 astromesh astromesh -
```

- [ ] **Step 3: Instalar ambos en el postinst**

En `mkosi.postinst.chroot`, justo antes de la línea final `echo "[postinst] done (mode=${MODE})"`, agregar:

```bash

# 9. Immutability (Fase 2a): /var is a first-boot systemd-repart partition; tmpfiles
#    recreates the runtime dirs on the fresh /var (which shadows the baked dirs).
install -d /usr/lib/repart.d
install -m 0644 "${SRC}/phase2/repart.d/50-var.conf" /usr/lib/repart.d/50-var.conf
install -m 0644 "${SRC}/phase2/tmpfiles/astromesh-var.conf" /usr/lib/tmpfiles.d/astromesh-var.conf
```

- [ ] **Step 4: Verificar**

Run:
```bash
bash -n mkosi.postinst.chroot && echo "postinst OK"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('phase2/repart.d/50-var.conf'); assert c['Partition']['Type']=='var'; print('var repart OK')"
```
Expected: `postinst OK`, `var repart OK`

- [ ] **Step 5: Commit**

```bash
git update-index --chmod=+x mkosi.postinst.chroot
git add phase2/repart.d phase2/tmpfiles mkosi.postinst.chroot
git commit -m "feat(phase2a): first-boot /var partition + tmpfiles for runtime dirs"
```

---

## Task 4: Oneshot de auto-chequeo de inmutabilidad

**Files:**
- Create: `phase2/immutability-check.sh`
- Create: `phase2/immutability-check.service`
- Modify: `mkosi.postinst.chroot`

- [ ] **Step 1: Crear `phase2/immutability-check.sh`**

```bash
#!/usr/bin/env bash
# Asserts the OS is immutable at boot and logs a single marker line to the console.
# - root must be read-only (write attempt fails)
# - dm-verity must be active for the root device
# - /var must be writable
set -uo pipefail

fail() { echo "IMMUTABILITY FAIL: $1"; exit 1; }

# 1. root read-only: writing to /usr (part of the verity root) must fail.
if touch /usr/.imm-probe 2>/dev/null; then
    rm -f /usr/.imm-probe 2>/dev/null || true
    fail "root is writable (/usr)"
fi

# 2. dm-verity active: a device-mapper device whose UUID marks it as a verity
#    target must exist. Read sysfs directly so we do not depend on dmsetup being
#    installed in the minimal image.
if ! grep -lq '^CRYPT-VERITY' /sys/block/dm-*/dm/uuid 2>/dev/null; then
    fail "no active dm-verity device"
fi

# 3. /var writable.
if ! touch /var/.imm-probe 2>/dev/null; then
    fail "/var is not writable"
fi
rm -f /var/.imm-probe 2>/dev/null || true

echo "IMMUTABILITY OK"
```

- [ ] **Step 2: Crear `phase2/immutability-check.service`**

```ini
[Unit]
Description=Astromesh OS immutability self-check
After=var.mount systemd-repart.service
Wants=systemd-repart.service

[Service]
Type=oneshot
ExecStart=/usr/lib/astromesh-os/immutability-check.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Instalar + habilitar en el postinst**

En `mkosi.postinst.chroot`, inmediatamente después del bloque de la sección 9 (las dos `install` de repart.d/tmpfiles), agregar:

```bash
install -d /usr/lib/astromesh-os
install -m 0755 "${SRC}/phase2/immutability-check.sh" /usr/lib/astromesh-os/immutability-check.sh
install -m 0644 "${SRC}/phase2/immutability-check.service" /etc/systemd/system/immutability-check.service
systemctl enable immutability-check.service
```

- [ ] **Step 4: Verificar**

Run:
```bash
bash -n phase2/immutability-check.sh && echo "check OK"
bash -n mkosi.postinst.chroot && echo "postinst OK"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('phase2/immutability-check.service'); assert 'oneshot' in c['Service']['Type']; print('service OK')"
```
Expected: `check OK`, `postinst OK`, `service OK`

- [ ] **Step 5: Hacer ejecutable y commit**

```bash
chmod +x phase2/immutability-check.sh
git update-index --chmod=+x phase2/immutability-check.sh mkosi.postinst.chroot
git add phase2/immutability-check.sh phase2/immutability-check.service mkosi.postinst.chroot
git commit -m "feat(phase2a): boot-time immutability self-check oneshot"
```

---

## Task 5: Harness — espacio para /var + aserción de inmutabilidad

**Files:**
- Modify: `tests/boot/run-and-assert.sh`

Dos cambios: (a) crecer el qcow2 antes de bootear, para que `systemd-repart` tenga espacio libre donde crear `/var`; (b) tras el boot-to-agent, asertar `IMMUTABILITY OK` en la consola.

- [ ] **Step 1: Crecer el disco antes de QEMU**

En `tests/boot/run-and-assert.sh`, justo después de la línea `IMAGE="${1:?usage: run-and-assert.sh <disk-image>}"`, agregar:

```bash
# Phase 2a: systemd-repart creates /var in free space on first boot, so the disk
# needs headroom beyond the minimized image.
qemu-img resize "${IMAGE}" +3G >/dev/null
```

- [ ] **Step 2: Asertar `IMMUTABILITY OK` tras el boot-to-agent**

En `tests/boot/run-and-assert.sh`, inmediatamente antes de la línea `echo "[boot] GATE PASSED"`, agregar:

```bash
echo "[boot] asserting immutability marker"
if grep -q "IMMUTABILITY OK" qemu-console.log; then
    echo "[boot] PASS: IMMUTABILITY OK"
else
    echo "[boot] FAIL: immutability marker not found"
    echo "----- immutability lines -----"; grep -i 'IMMUTABILITY' qemu-console.log || true
    exit 1
fi
```

- [ ] **Step 3: Verificar sintaxis**

Run: `bash -n tests/boot/run-and-assert.sh && echo "harness OK"`
Expected: `harness OK`

- [ ] **Step 4: Commit**

```bash
git update-index --chmod=+x tests/boot/run-and-assert.sh
git add tests/boot/run-and-assert.sh
git commit -m "test(phase2a): grow disk for /var and assert IMMUTABILITY OK"
```

---

## Task 6: Puesta en verde + iteración de verity/boot (CI)

**Files:** (ninguno nuevo — iteración sobre el boot inmutable)

El build verity + el boot con overlay/`/var` corren en CI. Esta tarea es el loop de ajuste (P2-1/P2-4).

- [ ] **Step 1: Pushear la rama y observar `phase0-ci`**

Run: `git push -u origin feat/phase2` luego, con el SHA de HEAD, esperar el run de `phase0-ci` y mirar los 3 jobs.
Expected: `build-deb` verde; `build-image` construye el layout verity; `boot-gate` bootea la imagen inmutable y asevera `IMMUTABILITY OK`.

- [ ] **Step 2: Diagnosticar fallos esperados con la consola**

Si `build-image` falla, leer el log de mkosi: la verity de mkosi 25.3 puede requerir knobs distintos (P2-4) — p. ej. `Verity=`/`VerityMatchKey=` en otra forma, o el roothash no embebido. Ajustar `mkosi.repart/` / `mkosi.conf` según el error y re-pushear.

Si `boot-gate` falla, leer `qemu-console.log` (el harness lo vuelca al fallar):
- **No bootea / no monta root**: roothash/verity mal embebido o initrd sin soporte verity → ajustar.
- **`systemd.volatile=overlay` rompe el boot**: probar primero sin el overlay (sólo verity RO) para aislar, luego reintroducir.
- **`/var` ausente / no writable**: revisar `systemd-repart` (espacio libre del disco — Task 5 resize), el `Type=var` y el auto-mount GPT.
- **`IMMUTABILITY FAIL: <razón>`**: el marcador dice qué falló (root writable / sin verity / /var RO) → corregir esa pieza.

Commit cada ajuste, re-pushear, repetir hasta verde.

- [ ] **Step 3: Confirmar el criterio de salida**

Expected (spec §5):
- `boot-gate` verde: imagen inmutable bootea + `IMMUTABILITY OK` + `/v1/health` 200 + `phase0-smoke` responde.
- `mkosi.finalize` within budget (≤ 500 MB) — confirmar que el rootfs no creció de forma inesperada.

- [ ] **Step 4: Cerrar Fase 2a**

Tildar la definición de hecho en `docs/superpowers/specs/2026-06-05-phase2a-immutability-design.md` (§5) con el run de referencia, y commitear. Siguiente ciclo: **Fase 2b** (A/B + `systemd-sysupdate` + rollback).

---

## Notas de cobertura del spec (self-review)

- §3.1 dm-verity root → Task 1 (`mkosi.repart/` data+hash). §3.2 overlay volátil → Task 2 (`systemd.volatile=overlay`).
- §3.3 `/var` repart + tmpfiles → Task 3. §3.4 oneshot de chequeo → Task 4. §3.5 harness extendido → Task 5.
- §2 arquitectura (ESP/root/verity/var) → Tasks 1+3. §1/§5 gate (IMMUTABILITY OK + boot-to-agent + ≤500MB) → Tasks 5+6.
- §4 riesgos P2-1..6 → Task 6 (loop de iteración con la consola serial). Verity sin firma (Secure Boot = Fase 3) → Task 1 (`Verity=data/hash` sin `VeritySignature`/keys).
