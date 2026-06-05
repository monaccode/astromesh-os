# astromesh-os — Fase 2a: Inmutabilidad (dm-verity + root read-only + /var persistente) (spec)

> **Estado:** Diseño aprobado (2026-06-05)
> **Sub-proyecto:** B (Inmutabilidad + Updates) — **parte 2a (inmutabilidad)**. La parte 2b (A/B + `systemd-sysupdate` + rollback) es un ciclo aparte.
> **Depende de:** [Fase 1](2026-06-05-phase1-minimal-image-design.md) — imagen mínima 244 MB, en `main`.
> **Entorno de build:** CI Linux (build en contenedor `debian:trixie` privilegiado, como Fase 0/1).

---

## 1. Objetivo y gate

**Objetivo:** convertir la imagen mínima de Fase 1 en una **imagen inmutable**: root **read-only protegido por dm-verity**, escrituras de runtime **efímeras** (overlay volátil), y estado persistente en una partición **`/var`** creada en el primer boot. El runtime sigue arrancando y respondiendo.

**Gate de salida (duro):**
1. La imagen bootea con **root verity read-only** y un oneshot de auto-chequeo loguea **`IMMUTABILITY OK`** (root no escribible + dm-verity activo + `/var` writable).
2. El **boot-to-agent de Fase 0/1 sigue pasando** (`/v1/health` 200 + `phase0-smoke` responde) — el runtime corre desde un `/opt` read-only.
3. La imagen sigue **≤ 500 MB** (gate `mkosi.finalize`).

**Fuera de alcance (ciclo 2b):** particiones A/B, `systemd-sysupdate`, rollback automático, transporte de updates. **Fuera de alcance (Fase 3):** firma de verity / Secure Boot — acá verity es **integridad sin firma**.

---

## 2. Arquitectura

```
Disco:
 ┌─────────┬──────────────┬───────────────┬──────────────────────────┐
 │  ESP    │  root (ro)   │  root-verity  │  /var (first-boot, grow) │
 │ (UKI)   │  dm-verity   │  hash tree    │  persistente             │
 └─────────┴──────────────┴───────────────┴──────────────────────────┘
        │ UKI cmdline: roothash=<…> console=ttyS0 …
        ▼
   root verity (RO genuino, verificado)  ← escrituras a /usr, /opt, /etc RECHAZADAS
        + /var (partición)                ← montado, persistente: memoria, logs
        + /run (tmpfs de systemd)          ← estado transitorio: machine-id, resolv, leases
        ▼
   astromesh-os.target → astromeshd (corre desde /opt read-only)
```

- **Inmutable (RO genuino):** todo el root (incl. `/usr`, `/opt/astromesh`, `/etc` horneado) bajo dm-verity, montado **read-only**; el VFS **rechaza** escrituras. Sin overlay volátil.
- **`/etc` stateless:** los defaults horneados son read-only; systemd absorbe lo transitorio (machine-id, `resolv.conf`, leases) en **`/run`** (tmpfs), sin estado persistente de config local (machine-config es Fase 4).
- **Persistente:** una partición `/var` creada y crecida por `systemd-repart` en el primer boot; aloja el estado del runtime.

---

## 3. Componentes

### 3.1 dm-verity sobre root (`mkosi.conf`)
- Habilitar verity en mkosi para que produzca **partición root + partición root-verity (hash)** y embeba `roothash=` en el cmdline del UKI. **Verity de integridad, sin firma** (Secure Boot = Fase 3).
- El root se monta **read-only** (verity es inherentemente RO).
- Verificar que el gate de tamaño (`mkosi.finalize`) sigue midiendo el rootfs correctamente con el layout verity.

### 3.2 `/etc` stateless sobre root read-only (sin overlay volátil)
- **No** se usa `systemd.volatile=overlay`: eso volvería todo el root escribible-pero-efímero, contradiciendo "root read-only". El root verity se monta RO y rechaza escrituras.
- systemd ya tolera `/etc` read-only redirigiendo lo transitorio a `/run`: machine-id transitorio (bind-mount desde `/run`), `resolv.conf` vía systemd-resolved en `/run`, leases de networkd en `/run`. Los defaults de config quedan horneados read-only.
- Si en CI algún servicio falla por querer escribir una ruta de `/etc`, se redirige esa ruta puntual a `/run` (symlink horneado o `tmpfiles`), no se afloja el root.

### 3.3 Partición `/var` (`systemd-repart` first-boot)
- `mkosi.repart/50-var.conf` (o `overlay/usr/lib/repart.d/50-var.conf`): define una partición `Type=var` con `SizeMinBytes`/`GrowFileSystem=yes` para crecer al disco en el primer boot.
- `systemd-repart.service` corre al boot y crea/crece `/var`; se monta persistente.
- `overlay/usr/lib/tmpfiles.d/astromesh-var.conf`: recrea `/var/lib/astromesh/{memory,data}` y `/var/log/astromesh` (con owner `astromesh`) sobre el `/var` fresco, porque la partición montada tapa los dirs horneados por el `.deb`.

### 3.4 Oneshot de auto-chequeo (`phase2/immutability-check.service` + script)
- Oneshot `WantedBy=multi-user.target`, corre temprano, loguea a consola:
  1. `touch /ro-probe 2>/dev/null && FAIL || ok` → root debe ser **no escribible**.
  2. dm-verity activo: presencia de un device-mapper verity (`/sys/block/dm-*/dm/uuid` empieza con `CRYPT-VERITY` o `veritysetup status` ok).
  3. `/var` writable: `touch /var/.imm-probe` → éxito, luego `rm`.
- Imprime `IMMUTABILITY OK` si los 3 pasan; `IMMUTABILITY FAIL: <razón>` si no.

### 3.5 Harness de boot (extendido, no rompe Fase 0/1)
- `tests/boot/run-and-assert.sh`: tras el boot-to-agent, **grepea `qemu-console.log` por `IMMUTABILITY OK`** y falla si no aparece.
- Como Fase 2a cambia `mkosi.conf` (verity para **todas** las builds), la imagen de `phase0-ci` (modo stub) también es inmutable y trae el oneshot → la aserción aplica de forma consistente; no se rompe nada.

---

## 4. Riesgos

| ID | Riesgo | Mitigación |
|----|--------|-----------|
| P2-1 | **Verity + overlay rompe el boot** (initrd no arma el overlay, roothash mal). | El boot-gate es el check; iterar con el `qemu-console.log` (consola serial ya forwardeada). Empezar por verity sólo, luego agregar el overlay. |
| P2-2 | **astromeshd escribe a una ruta read-only** ahora que root es RO. | En Fase 0/1 ya escribe sólo a `/var/lib/astromesh` y `/var/log/astromesh`. Confirmar con el boot-gate; si algo escribe a `/etc`/`/opt`, el tmpfs overlay lo absorbe (efímero) o se mueve a `/var`. |
| P2-3 | **`/var` no se crea/monta** → estado del runtime falla. | `systemd-repart` + tmpfiles validados por el boot-gate (si `/var` falta, astromeshd falla al escribir memoria/logs y el agente no responde). El oneshot también lo asevera. |
| P2-4 | **mkosi-repart de `/var`** depende de la versión de mkosi/systemd. | Build en contenedor trixie (mkosi 25.3, systemd 257) — versiones modernas con soporte repart maduro. Iterar en CI. |
| P2-5 | **El gate de tamaño** cambia con el layout verity. | `mkosi.finalize` mide el contenido del rootfs (`$BUILDROOT`), no el layout de particiones → debería seguir ~244 MB. Confirmar en la primera corrida. |
| P2-6 | **machine-id efímero** rompe algo que requiera id estable. | Para Fase 2a (sin mesh/identidad de nodo persistente — eso es Fase 4) un machine-id transitorio por boot es aceptable. Revisitar en Fase 4. |

---

## 5. Testing y criterio de "hecho" — ✅ CUMPLIDA (2026-06-05)

- [x] La imagen bootea con **root verity read-only**; el oneshot loguea **`IMMUTABILITY OK`** (root RO + dm-verity activo + `/var` writable). *(run 27037258203: `[boot] PASS: IMMUTABILITY OK`).*
- [x] **Boot-to-agent de Fase 0/1 sigue verde** sobre la imagen inmutable (`/v1/health` 200 + `phase0-smoke` → `{"answer":"pong"}`, corriendo desde `/opt` read-only).
- [x] El estado del runtime persiste en `/var` (writable). *`/etc` queda **read-only genuino** (estado transitorio en `/run`), no overlay — ver §3.2 corregido.*
- [x] Imagen **≤ 500 MB** (`mkosi.finalize` within budget, **244MB**).

### Aprendizajes de verity en mkosi 25.3 (9 iteraciones de CI)
El layout verity por `mkosi.repart/` custom requirió, en orden: `Minimize=best` no se permite en fs writable → `Minimize=guess` en la data ext4; quitar `Minimize` de la partición verity-hash (crash de repart en `context_minimize`); darle `SizeMinBytes=32M` a la hash (repart sub-asignaba 4K); `CopyFiles=/efi:/`+`/boot:/` en la ESP (sino queda vacía → firmware no encuentra el UKI); **`CopyFiles=/` en la data root** (sino la partición root y el árbol verity quedan vacíos → switch-root falla por os-release ausente — la causa de fondo); y `/var` horneado con `MountPoint=/var` en vez de first-boot repart (el auto-discovery de `/var` exige UUID derivado de machine-id y el timing era poco confiable). Insumo directo para Fase 2b (A/B sobre el mismo layout).

Cumplido → siguiente ciclo: **Fase 2b** (A/B con `systemd-sysupdate` + rollback automático; transporte de updates).
