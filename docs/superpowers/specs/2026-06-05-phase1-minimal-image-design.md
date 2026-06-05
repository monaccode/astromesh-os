# astromesh-os — Fase 1: Imagen mínima + boot-to-agent + gate de tamaño + ORAS (spec)

> **Estado:** Diseño aprobado (2026-06-05)
> **Sub-proyectos:** A (OS Build, completo) + G (Distribución/cloud, mínimo)
> **Depende de:** [Fase 0](2026-06-05-phase0-validation-design.md) — ✅ verde en CI.
> **Entorno de build:** CI Linux (build de imagen en contenedor `debian:trixie` privilegiado, como en Fase 0).

---

## 1. Objetivo y gate

**Objetivo:** convertir la imagen estándar de Fase 0 en una **imagen mínima de cloud** que arranque directo a `astromeshd` (target boot-to-agent), respete el **techo de tamaño ≤ 500 MB** (build falla si lo excede), y se **publique como artefacto OCI vía ORAS**.

**Gate de salida (duro):**
1. La imagen core (sin GPU) mide **≤ 500 MB** — `mkosi.finalize` **falla el build** si se excede.
2. La imagen sigue pasando el **boot-to-agent de Fase 0** (`/v1/health` 200 + `phase0-smoke` responde) — el recorte no rompe el runtime.
3. `phase1-publish` empuja el `.raw` como artefacto OCI vía ORAS (validado en dry-run; push real en tag/manual con secret).

---

## 2. Alcance

**Incluido:**
- Recorte agresivo de la imagen para entrar en ≤ 500 MB (§4).
- `mkosi.finalize` que mide el rootfs y aplica el gate de tamaño (§5).
- Target `astromesh-os.target` como `default.target`, con `astromeshd` como propósito; **getty conservado** (§6).
- Tooling ORAS (`push.sh`/`pull.sh` + media types + esquema de tags) y workflow de publicación gateado (§7).
- Artefacto de salida: **disco `.raw` genérico**, publicado vía ORAS.

**NO incluido (fases posteriores):**
- Conversión cloud específica (AMI / Azure VHD / GCP image) → ciclo posterior de G.
- Inmutabilidad / dm-verity / A/B updates → Fase 2.
- No-shell / break-glass / seguridad TPM → Fase 3 (por eso **getty se conserva** ahora).
- sysext, Maia, §12 → Fase 4+.

> **Principio:** el recorte no debe romper el contrato de Fase 0. El harness de boot es la red de seguridad.

---

## 3. Punto de partida (medido en Fase 0)

Del build de Fase 0 (run `27027974832`): la partición root mínima fue **531 MB**, el `.raw` consume **~612 MB**. mkosi ya excluye `/usr/share/doc` y `/usr/share/man` (visto en las opciones de dpkg del build). El término dominante es el **closure de Python** del runtime (`/opt/astromesh/venv`), más una **duplicación**: el venv del runtime ya trae fastapi/uvicorn/pydantic, y además se instalan los paquetes apt `python3-fastapi`/`python3-uvicorn` para el stub.

---

## 4. Estrategia de recorte (llegar a ≤ 500 MB)

Palancas, ordenadas por impacto esperado:

1. **Dedup fastapi/uvicorn (la más directa).** El stub corre hoy con el `python3 -m uvicorn` del sistema (paquetes apt). En su lugar, correrlo con el intérprete del **venv del runtime**, que ya incluye fastapi/uvicorn/pydantic:
   - `phase0-stub.service` → `ExecStart=/opt/astromesh/venv/bin/python -m uvicorn stub_server:app …`.
   - Quitar `python3-fastapi` y `python3-uvicorn` de `mkosi.conf` `Packages=`.
   - Esto elimina una copia completa del stack web del cierre de la imagen.
2. **Strip del venv del runtime (en `mkosi.postinst.chroot`, tras instalar el `.deb`).** Purgar dentro de `/opt/astromesh/venv`:
   - todos los `__pycache__/` y `*.pyc`;
   - directorios `tests/` y `test/` dentro de `site-packages/*`;
   - inventariar qué arrastró `astromesh[...systemd]` y, si vinieron deps **opcionales** no usadas por el core (clientes de vector stores, RAG, ONNX/GPU), removerlas. **Sólo** las que no afecten a `astromeshd` arrancando y respondiendo (validado por el harness de boot).
3. **Locales y `/usr/share` residual.** Excluir locales no-C vía mkosi (`RemoveFiles=`/`--path-exclude`), y restos de `/usr/share/{info,lintian,bug,…}`.
4. **Kernel/initrd.** `linux-image-cloud-amd64` ya es el variante chico. Evaluar un initrd con sólo drivers virtio (mkosi initrd o `KernelModulesInclude=`/`KernelModulesExclude=`), sin firmware de hardware físico.

**Medición de control:** `mkosi.finalize` loguea el desglose (`du -sh` de `/opt/astromesh/venv`, `/usr/lib/modules`, `/usr`) para ver dónde está el peso.

**Escape hatch (honestidad):** si tras 1–4 el closure de Python no baja de 500 MB sin romper `astromeshd`, `mkosi.finalize` reporta el tamaño alcanzado y el desglose, y se eleva la decisión al usuario (techo real vs recorte adicional de función) **en vez de** subir el techo en silencio.

---

## 5. Gate de tamaño (`mkosi.finalize`)

Script `mkosi.finalize` (corre al final del build, con el rootfs montado en `$BUILDROOT`):
- Calcula `USED=$(du -sb "$BUILDROOT" | cut -f1)` → MB.
- Loguea siempre: `[finalize] rootfs size: <X> MB (budget <BUDGET> MB)` + desglose de los directorios pesados.
- `BUDGET=${PHASE1_SIZE_BUDGET_MB:-500}`. Si `X > BUDGET` → `echo "[finalize] OVER BUDGET"; exit 1` (falla el build).
- También se mide el `.raw` producido (tamaño consumido) como dato secundario.

> El gate vive en `finalize` (no en un step de CI aparte) para que **cualquier** build —local o CI— falle igual al excederse, cumpliendo §7/§11 del spec maestro.

---

## 6. Target boot-to-agent

**Archivos (overlay horneado en la imagen):**
- `overlay/usr/lib/systemd/system/astromesh-os.target` — target propósito:
  ```ini
  [Unit]
  Description=Astromesh OS boot-to-agent target
  Requires=multi-user.target astromeshd.service
  After=multi-user.target astromeshd.service
  AllowIsolate=yes
  ```
  `Requires=multi-user.target` mantiene la red (systemd-networkd) y getty arriba; `Requires=astromeshd.service` hace del daemon el propósito. **No se usa drop-in `[Install]`** para enganchar astromeshd al target: un `[Install] WantedBy=` dentro de un drop-in es ignorado por `systemctl enable` (limitación documentada de systemd); el `Requires=` del target es lo que arranca el daemon.
- `mkosi.postinst.chroot`: instala el target desde `$SRCDIR` y `systemctl set-default astromesh-os.target`; **sin** tocar `getty@` (se conserva para diagnóstico hasta Fase 3).

**Contrato:** el boot llega a `astromesh-os.target`, que garantiza `astromeshd` activo. El harness de Fase 0 sigue siendo el check (la red + API ya validan que el target cumple su propósito).

---

## 7. Publicación ORAS (sub-proyecto G, mínimo)

**Archivos:** `cloud/oras/push.sh`, `cloud/oras/pull.sh`, `cloud/oras/media-types.md`, `.github/workflows/phase1-publish.yml`.

- **Esquema (fijado, ver §6.10 del spec maestro):** tags `MAJOR.MINOR.PATCH` + `latest` + sufijos de variante; media types propios:
  - `application/vnd.astromesh.disk.raw` (la imagen core).
  - (reservado) `application/vnd.astromesh.sysext.<n>` para fases futuras.
- **`push.sh`:** `oras push docker.io/<org>/astromesh-os:<tag> <raw>:application/vnd.astromesh.disk.raw` (+ `:latest`). Parametriza repo/tag por env; NO `docker push` (es disco, no contenedor).
- **`pull.sh`:** `oras pull docker.io/<org>/astromesh-os:<tag>` → deja el `.raw` para provisioning/sysupdate.
- **Workflow `phase1-publish.yml`:** se dispara en **tag `v*`** o `workflow_dispatch`. Construye la imagen (reusa el job de build en contenedor trixie), luego `oras push` autenticado con el secret `DOCKERHUB_TOKEN`. **Si no hay secret** (PRs/push normales): instala `oras`, valida `bash -n` de los scripts y hace `oras push --dry-run`-equivalent (o sólo valida), **sin** push real. Espeja el patrón no-op del `phase0-nightly`.

---

## 8. Testing y criterio de "hecho" — ✅ CUMPLIDA (2026-06-05)

- [x] `mkosi.finalize` mide y **falla** si > 500 MB; en verde, la imagen mide **≤ 500 MB**. *(run 27031436983: `[finalize] within budget (244/500 MB)` — los recortes bajaron de ~612MB a **244MB**).*
- [x] El **boot-to-agent de Fase 0 sigue pasando** sobre la imagen recortada. *(`/v1/health` 200 + `phase0-smoke` → `{"answer":"pong"}`; `doctor` ahora `provider:primary: ok`).*
- [x] `default.target` = `astromesh-os.target` y el boot alcanza `astromeshd` activo. *(el boot-gate sólo pasa si el target arranca astromeshd y la red sube).*
- [x] `phase1-publish` valida el tooling ORAS sin secret (no-op) — corrido vía tag de prueba. *(push real del artefacto OCI: pendiente del primer tag de release con secret `DOCKERHUB_TOKEN`).*
- [x] **≤ 500 MB resultó factible con margen** (244MB) — el escape hatch (§4) no fue necesario.

> **Nota de margen:** 244MB deja ~256MB de cabecera bajo el techo, holgura para el `sysext-gpu` y la inmutabilidad de fases siguientes sin tocar el core. El desglose `du -sh` por path salió vacío en `mkosi.finalize` (cosmético; la medición total y el gate funcionan) — mejorar el desglose es trabajo menor para Fase 2.

Cumplido → siguiente ciclo: **Fase 2** (inmutabilidad: dm-verity, root RO, A/B `sysupdate` + rollback).

---

## 9. Riesgos

| ID | Riesgo | Mitigación |
|----|--------|-----------|
| P1-1 | **Recorte rompe `astromeshd`** (se quita una dep que el core sí usa). | El harness de boot de Fase 0 es el gate: cualquier recorte que rompa el arranque/respuesta falla CI. Remover deps de a poco, re-validando. |
| P1-2 | **≤ 500 MB infactible** por el closure de Python. | Escape hatch §4: medir, reportar desglose, elevar decisión; no subir el techo en silencio. |
| P1-3 | **Stub depende del venv del runtime** (dedup) y el venv cambia entre versiones del `.deb`. | El stub sólo usa fastapi/uvicorn, presentes en el closure del runtime; si una versión del runtime los excluyera, el dedup se revierte a paquetes apt (documentado). |
| P1-4 | **`set-default` o drop-ins rompen el boot** en el chroot. | Validar con el harness; `getty` conservado da diagnóstico. |
| P1-5 | **ORAS push** con credenciales/esquema mal fijados es costoso de cambiar luego. | Media types y tags **fijados en §7 antes del primer push**; push real sólo en tag con secret. |
