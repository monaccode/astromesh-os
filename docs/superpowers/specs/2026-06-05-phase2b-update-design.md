# astromesh-os — Fase 2b-update: A/B + systemd-sysupdate (aplicar update y bootear el nuevo slot) (spec)

> **Estado:** Diseño aprobado (2026-06-05)
> **Sub-proyecto:** B (Inmutabilidad + Updates) — **parte 2b-update**. El **rollback automático** (boot-assessment) es el ciclo siguiente **2b-rollback**.
> **Depende de:** [Fase 2a](2026-06-05-phase2a-immutability-design.md) — imagen verity inmutable, en `main`.
> **Entorno de build:** CI Linux (build en contenedor `debian:trixie` privilegiado).

---

## 1. Objetivo y gate

**Objetivo:** dar a la imagen inmutable **updates A/B atómicos** con `systemd-sysupdate`: dos slots de root (verity) + UKIs versionados; sysupdate descarga una versión nueva al slot inactivo y el sistema bootea esa versión. **El rollback automático NO está en este ciclo.**

**Gate de salida (duro):**
1. **`systemd-sysupdate` aplica v2** al slot inactivo y, tras reboot, el sistema **bootea v2** — el harness multi-boot asevera `ASTROMESH_BUILD=2` en consola (partiendo de `ASTROMESH_BUILD=1`).
2. El **boot único de Fase 0/1/2a sigue verde** (`phase0-ci`) sobre el nuevo layout A/B: la imagen v1 bootea, `IMMUTABILITY OK`, `/v1/health` 200, `phase0-smoke` responde.
3. Tamaño dentro de presupuesto (el segundo slot vacío no cuenta como contenido del rootfs).

**Fuera de alcance:** rollback automático / boot-assessment (`2b-rollback`); transporte de producción real (ORAS/Docker Hub → sysupdate-HTTP) — en este ciclo el origen es un **HTTP local** para el test.

---

## 2. Arquitectura

```
Disco (A/B sobre el verity de Fase 2a):
 ┌──────┬─────────────┬──────────────┬─────────────┬──────────────┬──────────┐
 │ ESP  │ root-A data │ verity-A hash│ root-B data │ verity-B hash│  /var    │
 │ UKIs │ (v1)        │              │ (vacío→v2)  │              │ compart. │
 └──────┴─────────────┴──────────────┴─────────────┴──────────────┴──────────┘
   │ systemd-boot bootea el UKI más nuevo (entradas Type 2 versionadas)
   ▼
 systemd-sysupdate: descarga v_n+1 (root+verity+UKI) al slot inactivo, instala el UKI
```

- **A/B:** dos pares root(data)+verity(hash). systemd-sysupdate elige el slot inactivo y escribe la versión nueva; systemd-boot bootea el UKI de mayor versión.
- **Atómico:** la versión nueva se escribe entera al slot inactivo; el switch es elegir el UKI nuevo en el próximo boot.
- **/var compartido:** persiste entre versiones (estado del runtime).

---

## 3. Componentes

### 3.1 Layout A/B (`mkosi.repart`)
Sobre el layout de Fase 2a (ESP + root-A + verity-A + /var), agregar el segundo slot:
- `mkosi.repart/40-root-b.conf`: `Type=root`, `Label=root-b`, **sin** `CopyFiles` (vacío; sysupdate lo llena), tamaño ≥ el de root-A. `ReadOnly=yes`.
- `mkosi.repart/50-verity-b.conf`: `Type=root-verity`, `Label=verity-b`, `SizeMinBytes=32M`.
- El slot A conserva `CopyFiles=/` (poblado con v1). Los `VerityMatchKey` se separan por slot (`root` para A, `root-b` para B) para que cada par data+hash matchee.
- Renombrar `Label`/`VerityMatchKey` de A a `root-a`/`verity-a` para simetría (o dejar A como está y B como `root-b`).

### 3.2 Artefactos versionados (`mkosi.conf`)
- `ImageVersion=` parametrizable (env `IMAGE_VERSION`, default `1`) → mkosi nombra los artefactos con la versión.
- **`SplitArtifacts=root,verity,uki`** (o el equivalente de mkosi 25.3) → además del `.raw` completo, mkosi emite por versión: `<id>_<ver>.root-x86-64.raw`, `<id>_<ver>.root-x86-64-verity.raw`, y el UKI `<id>_<ver>.efi`. Son lo que sysupdate descarga.

### 3.3 `systemd-sysupdate` (`phase2b/sysupdate.d/*.transfer`, horneados en `/usr/lib/sysupdate.d/`)
- `10-uki.transfer`: `[Source] Type=url-file`, `Path=http://10.0.2.2:<PORT>/`, `MatchPattern=<id>_@v.efi`; `[Target] Type=regular-file`, `Path=/EFI/Linux/` (en el ESP), `MatchPattern=<id>_@v.efi`, `InstancesMax=2`.
- `20-root.transfer`: `[Source]` `MatchPattern=<id>_@v.root-x86-64.raw`; `[Target] Type=partition`, `MatchPattern=root-@v` (slots A/B por label), `InstancesMax=2`.
- `30-verity.transfer`: análogo para `…-verity.raw` y la partición verity.
- `10.0.2.2` es la IP del host en QEMU user-net; el `<PORT>` lo sirve el harness (§3.6).

### 3.4 Trigger de update (`phase2b/astromesh-autoupdate.{service,sh}`)
- Oneshot tras boot (`After=astromeshd.service network-online.target`): corre `/usr/lib/systemd/systemd-sysupdate update` (o `systemctl start systemd-sysupdate`). Si un update se instaló (versión nueva disponible), `systemctl reboot`.
- **No-op si la fuente es inalcanzable** (`|| true` + chequeo de "ningún update"): en `phase0-ci` no hay servidor en `10.0.2.2:<PORT>` → sysupdate no encuentra nada → sin reboot. Sólo actúa en el test 2b (con v2 servido).

### 3.5 Marcador de versión (`phase2b/version-marker.{service,sh}`)
- Oneshot que loguea `ASTROMESH_BUILD=<ImageVersion>` a consola (la `ImageVersion` se hornea en `/usr/lib/astromesh-os/build-version`). Mismo patrón que `IMMUTABILITY OK`.

### 3.6 Harness multi-boot (`tests/boot/update-and-assert.sh`) + workflow
- **`phase2b-update.yml`**: build **v1** (imagen completa, `IMAGE_VERSION=1`) + build **v2** (split artifacts, `IMAGE_VERSION=2`). Stagear los artefactos de v2 en un dir servido por `python3 -m http.server <PORT>`.
- `update-and-assert.sh`:
  1. Arranca QEMU **persistente** (sin `-no-reboot`; user-net con `hostfwd :8000` y acceso del guest al host vía `10.0.2.2`).
  2. Espera health + asevera `ASTROMESH_BUILD=1`.
  3. El `autoupdate.service` del guest fetchea v2 → `systemctl reboot` (QEMU sobrevive el reboot).
  4. Tras el reboot: re-espera health 200 + asevera **`ASTROMESH_BUILD=2`** en la consola post-reboot → update aplicado y booteado.
- `phase0-ci` (boot único de v1 sobre el layout A/B) **sigue siendo el gate de regresión**.

---

## 4. Riesgos

| ID | Riesgo | Mitigación |
|----|--------|-----------|
| P2b-1 | **mkosi `SplitArtifacts`/`ImageVersion`** con nombres/knobs distintos en 25.3. | Iterar en CI con el log de mkosi; confirmar los nombres reales de los artefactos split y ajustar los `MatchPattern`. |
| P2b-2 | **sysupdate no matchea** los artefactos (patrón/URL). | `systemd-sysupdate list` en el guest (vía consola/log) muestra qué ve; ajustar `MatchPattern`/`Path`. Origen `10.0.2.2` debe ser alcanzable desde el guest (user-net). |
| P2b-3 | **A/B + verity**: el slot B necesita su propio roothash en el UKI v2. | mkosi v2 genera el UKI con su roothash; sysupdate instala ese UKI. El UKI lleva su `roothash=` embebido (como en 2a). |
| P2b-4 | **Reboot del guest en CI** mata QEMU o el harness pierde el hilo. | NO usar `-no-reboot`; el harness re-poll health tras el reboot. Distinguir el segundo boot por el marcador de versión, no por timing. |
| P2b-5 | **autoupdate dispara en `phase0-ci`** y rompe el boot único. | Sin servidor en la URL → sysupdate no encuentra versión nueva → no-op, sin reboot. Verificar que el fallo de red es tolerado. |
| P2b-6 | **El segundo slot infla el tamaño/disco.** | root-B va vacío (sin `CopyFiles`); el gate mide el contenido del rootfs (slot A), no el slot vacío. El disco se agranda para los dos slots; el harness hace `qemu-img resize` suficiente. |

---

## 5. Testing y criterio de "hecho"

- [ ] `phase2b-update.yml` verde: arranca v1 (`ASTROMESH_BUILD=1`), `systemd-sysupdate` aplica v2 al slot inactivo, reboot, y el sistema bootea **v2** (`ASTROMESH_BUILD=2`) con `/v1/health` 200.
- [ ] `phase0-ci` sigue verde sobre el layout A/B (v1 bootea, `IMMUTABILITY OK`, agente responde).
- [ ] Tamaño dentro de presupuesto (el slot B vacío no cuenta como contenido del rootfs).

Cumplido → siguiente ciclo: **2b-rollback** (boot-assessment / boot-counting: un v2 que no llega a healthy se revierte automáticamente a v1).
