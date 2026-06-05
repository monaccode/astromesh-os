# astromesh-os Fase 1 (Imagen mínima + boot-to-agent + gate de tamaño + ORAS) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recortar la imagen de Fase 0 a una imagen mínima de cloud (≤ 500 MB, gate que falla el build), arrancar directo a `astromeshd` vía un target boot-to-agent, y publicar el disco como artefacto OCI vía ORAS — sin romper el boot-to-agent de Fase 0.

**Architecture:** Se construye sobre la imagen de Fase 0 (ya verde en CI, branch `feat/phase1` parte de `main`). El recorte ataca el término dominante (el venv de Python del runtime) mediante dedup (el stub usa el intérprete del venv del runtime en vez de paquetes apt), strip del venv y exclusión de locales. Un `mkosi.finalize` mide el rootfs y falla si excede el presupuesto. El target `astromesh-os.target` hace de `astromeshd` el propósito del sistema. ORAS publica el `.raw` como artefacto OCI (no contenedor).

**Tech Stack:** mkosi (en contenedor `debian:trixie` privilegiado), systemd, QEMU/OVMF, ORAS, GitHub Actions, bash.

**Spec:** `docs/superpowers/specs/2026-06-05-phase1-minimal-image-design.md`

**Restricción de entorno:** host Windows; build/boot autoritativos en CI Linux (igual que Fase 0). Verificaciones host-runnable: `bash -n`, `python -c configparser/yaml`. El gate real (tamaño + boot + publish) corre en CI.

---

## File Structure

| Archivo | Responsabilidad |
|---------|-----------------|
| `mkosi.finalize` | Mide el rootfs, loguea desglose, **falla** si > presupuesto. |
| `mkosi.conf` | Quitar `python3-fastapi`/`python3-uvicorn`; agregar `RemoveFiles=` (locales/info). |
| `tests/stub-openai/phase0-stub.service` | Stub corre con el python del venv del runtime (dedup). |
| `mkosi.postinst.chroot` | Strip del venv; instalar el target + drop-in; `set-default`. |
| `phase1/astromesh-os.target` | Target boot-to-agent. |
| `phase1/astromeshd-target.conf` | Drop-in `WantedBy=astromesh-os.target`. |
| `cloud/oras/push.sh` | `oras push` del `.raw` como artefacto OCI. |
| `cloud/oras/pull.sh` | `oras pull` del artefacto. |
| `cloud/oras/media-types.md` | Esquema fijo de tags + media types. |
| `.github/workflows/phase1-publish.yml` | Build + publish ORAS gateado (tag/manual + secret). |

> El boot-to-agent de Fase 0 (`tests/boot/run-and-assert.sh`, `phase0-ci.yml`) **no se modifica** y sigue siendo el gate de regresión.

---

## Task 1: Gate de tamaño (`mkosi.finalize`)

**Files:**
- Create: `mkosi.finalize`

`mkosi.finalize` corre al final del build con el rootfs en `$BUILDROOT`. Mide, loguea el desglose, y falla si excede el presupuesto. Se implementa primero para tener medición desde el inicio del recorte (los primeros builds pueden fallar el gate hasta que el recorte baje el tamaño — es lo esperado).

- [ ] **Step 1: Crear `mkosi.finalize`**

```bash
#!/usr/bin/env bash
# Runs at the end of the mkosi build with the assembled rootfs at $BUILDROOT.
# Measures the image, logs a breakdown of the heavy directories, and fails the
# build if it exceeds the size budget (Phase 1 hard gate, spec §5).
set -euo pipefail

BUDGET_MB="${PHASE1_SIZE_BUDGET_MB:-500}"
ROOT="${BUILDROOT:?BUILDROOT not set}"

used_bytes=$(du -sb "${ROOT}" | cut -f1)
used_mb=$(( used_bytes / 1024 / 1024 ))

echo "[finalize] rootfs size: ${used_mb} MB (budget ${BUDGET_MB} MB)"
echo "[finalize] heaviest paths:"
du -sh "${ROOT}/opt/astromesh" "${ROOT}/usr/lib/modules" "${ROOT}/usr/lib" \
       "${ROOT}/usr/bin" "${ROOT}/usr/share" 2>/dev/null | sort -rh | head -10 || true
echo "[finalize] venv site-packages top dirs:"
du -sh "${ROOT}"/opt/astromesh/venv/lib/python*/site-packages/* 2>/dev/null \
    | sort -rh | head -15 || true

if [ "${used_mb}" -gt "${BUDGET_MB}" ]; then
    echo "[finalize] OVER BUDGET by $(( used_mb - BUDGET_MB )) MB"
    exit 1
fi
echo "[finalize] within budget (${used_mb}/${BUDGET_MB} MB)"
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n mkosi.finalize && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 3: Hacer ejecutable y commit**

```bash
chmod +x mkosi.finalize
git update-index --chmod=+x mkosi.finalize 2>/dev/null || git add mkosi.finalize
git add mkosi.finalize
git commit -m "feat(phase1): add mkosi.finalize size gate with breakdown logging"
```

---

## Task 2: Dedup fastapi/uvicorn (stub usa el venv del runtime)

**Files:**
- Modify: `tests/stub-openai/phase0-stub.service`
- Modify: `mkosi.conf` (quitar `python3-fastapi`, `python3-uvicorn`)

El runtime es una app FastAPI, así que su venv (`/opt/astromesh/venv`) ya incluye fastapi/uvicorn/pydantic. El stub puede usar ese intérprete, eliminando los paquetes apt duplicados de la imagen.

- [ ] **Step 1: Apuntar el stub al python del venv del runtime**

En `tests/stub-openai/phase0-stub.service`, cambiar la línea `ExecStart`:

```ini
ExecStart=/opt/astromesh/venv/bin/python -m uvicorn stub_server:app --host 127.0.0.1 --port 8081
```

- [ ] **Step 2: Quitar los paquetes apt duplicados**

En `mkosi.conf`, eliminar exactamente estas dos líneas del bloque `Packages=`:

```
        python3-fastapi
        python3-uvicorn
```

- [ ] **Step 3: Verificar configs**

Run:
```bash
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('tests/stub-openai/phase0-stub.service'); assert '/opt/astromesh/venv/bin/python' in c['Service']['ExecStart']; print('stub OK')"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('mkosi.conf'); print('mkosi.conf OK')"
grep -q 'python3-fastapi' mkosi.conf && echo 'STILL PRESENT (bad)' || echo 'fastapi removed OK'
```
Expected: `stub OK`, `mkosi.conf OK`, `fastapi removed OK`

- [ ] **Step 4: Commit**

```bash
git add tests/stub-openai/phase0-stub.service mkosi.conf
git commit -m "feat(phase1): dedup fastapi/uvicorn — stub uses the runtime venv python"
```

---

## Task 3: Strip del venv del runtime

**Files:**
- Modify: `mkosi.postinst.chroot`

Después de instalar el `.deb` y reescribir los shebangs (Fase 0), purgar caches de bytecode y directorios de tests del venv. Se inserta justo después del bloque de fix de shebangs (sección "1b") y antes de la sección "2".

- [ ] **Step 1: Leer el contexto de inserción**

Run: `grep -n "astromeshd shebang after fix" mkosi.postinst.chroot`
Expected: una línea (el final de la sección 1b).

- [ ] **Step 2: Insertar el strip del venv**

Inmediatamente después de la línea `echo "[postinst] astromeshd shebang after fix:"; head -1 /opt/astromesh/venv/bin/astromeshd 2>&1 || true`, agregar:

```bash

# 1c. Trim the venv to help fit the size budget (spec §4.2): bytecode caches and
#     in-package test dirs. Only safe-to-remove artefacts; the boot-to-agent gate
#     guards against removing anything the runtime needs.
echo "[postinst] stripping venv caches/tests"
find /opt/astromesh/venv -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find /opt/astromesh/venv -type f -name '*.pyc' -delete 2>/dev/null || true
find /opt/astromesh/venv -type d \( -name tests -o -name test \) \
    -path '*/site-packages/*' -prune -exec rm -rf {} + 2>/dev/null || true
```

- [ ] **Step 3: Verificar sintaxis**

Run: `bash -n mkosi.postinst.chroot && echo "postinst OK"`
Expected: `postinst OK`

- [ ] **Step 4: Commit**

```bash
git update-index --chmod=+x mkosi.postinst.chroot
git add mkosi.postinst.chroot
git commit -m "feat(phase1): strip venv bytecode caches and test dirs"
```

---

## Task 4: Excluir locales y /usr/share residual

**Files:**
- Modify: `mkosi.conf` (agregar `RemoveFiles=` en `[Content]`)

- [ ] **Step 1: Agregar `RemoveFiles=`**

En `mkosi.conf`, dentro de la sección `[Content]` (después de la línea `Environment=PHASE0_MODE`), agregar:

```ini
RemoveFiles=
        /usr/share/locale
        /usr/share/i18n/locales
        /usr/share/info
        /usr/share/lintian
        /usr/share/doc
        /usr/share/man
```

- [ ] **Step 2: Verificar que el INI parsea**

Run: `python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('mkosi.conf'); assert 'RemoveFiles' in c['Content']; print('mkosi.conf OK')"`
Expected: `mkosi.conf OK`

- [ ] **Step 3: Commit**

```bash
git add mkosi.conf
git commit -m "feat(phase1): remove locales/info/doc/man from the image"
```

---

## Task 5: Target boot-to-agent

**Files:**
- Create: `phase1/astromesh-os.target`
- Create: `phase1/astromeshd-target.conf`
- Modify: `mkosi.postinst.chroot`

El target se hornea instalándolo desde `$SRCDIR` en el postinst (mismo patrón que los agentes en Fase 0 — evita la incógnita de orden de `mkosi.extra`).

- [ ] **Step 1: Crear el target**

Create `phase1/astromesh-os.target`:

```ini
[Unit]
Description=Astromesh OS boot-to-agent target
Documentation=https://github.com/monaccode/astromesh-os
# Pull in the normal system (systemd-networkd, getty, ...) so the API is reachable,
# AND make astromeshd a hard requirement of reaching the target — it is the purpose.
Requires=multi-user.target astromeshd.service
After=multi-user.target astromeshd.service
AllowIsolate=yes
```

- [ ] **Step 2: Crear el drop-in del servicio**

Create `phase1/astromeshd-target.conf`:

```ini
[Install]
WantedBy=astromesh-os.target
```

- [ ] **Step 3: Instalar el target en el postinst**

En `mkosi.postinst.chroot`, justo antes de la línea final `echo "[postinst] done (mode=${MODE})"`, agregar:

```bash

# 8. Boot-to-agent target: make astromeshd the purpose of the system. getty is
#    intentionally kept (no-shell is Fase 3).
install -m 0644 "${SRC}/phase1/astromesh-os.target" /usr/lib/systemd/system/astromesh-os.target
install -d /etc/systemd/system/astromeshd.service.d
install -m 0644 "${SRC}/phase1/astromeshd-target.conf" \
    /etc/systemd/system/astromeshd.service.d/20-target.conf
systemctl set-default astromesh-os.target
```

- [ ] **Step 4: Verificar**

Run:
```bash
bash -n mkosi.postinst.chroot && echo "postinst OK"
python -c "import configparser; c=configparser.ConfigParser(strict=False,allow_no_value=True); c.read('phase1/astromesh-os.target'); assert 'astromeshd.service' in c['Unit']['Requires']; print('target OK')"
```
Expected: `postinst OK`, `target OK`

- [ ] **Step 5: Commit**

```bash
git update-index --chmod=+x mkosi.postinst.chroot
git add phase1/ mkosi.postinst.chroot
git commit -m "feat(phase1): boot-to-agent target (astromesh-os.target as default)"
```

---

## Task 6: Tooling ORAS

**Files:**
- Create: `cloud/oras/push.sh`
- Create: `cloud/oras/pull.sh`
- Create: `cloud/oras/media-types.md`

- [ ] **Step 1: Crear `push.sh`**

Create `cloud/oras/push.sh`:

```bash
#!/usr/bin/env bash
# Publishes the Phase 1 disk image as an OCI ARTIFACT (not a container) via ORAS.
# The artifact is a disk — consume it with `oras pull` + provisioning, never
# `docker run`/`docker pull`.
set -euo pipefail

REPO="${ORAS_REPO:?set ORAS_REPO, e.g. docker.io/monaccode/astromesh-os}"
TAG="${ORAS_TAG:?set ORAS_TAG, e.g. 0.1.0}"
RAW="${1:?usage: push.sh <disk.raw>}"
MEDIA="application/vnd.astromesh.disk.raw"

[ -f "${RAW}" ] || { echo "push.sh: no such file: ${RAW}" >&2; exit 1; }

echo "[oras] pushing ${RAW} -> ${REPO}:${TAG} (${MEDIA})"
oras push "${REPO}:${TAG}" "${RAW}:${MEDIA}"
oras push "${REPO}:latest" "${RAW}:${MEDIA}"
echo "[oras] done"
```

- [ ] **Step 2: Crear `pull.sh`**

Create `cloud/oras/pull.sh`:

```bash
#!/usr/bin/env bash
# Pulls the disk artifact (NOT a container) for provisioning / sysupdate.
set -euo pipefail

REPO="${ORAS_REPO:?set ORAS_REPO, e.g. docker.io/monaccode/astromesh-os}"
TAG="${ORAS_TAG:-latest}"

echo "[oras] pulling ${REPO}:${TAG}"
oras pull "${REPO}:${TAG}"
echo "[oras] done — the .raw is now in the current directory"
```

- [ ] **Step 3: Crear `media-types.md`**

Create `cloud/oras/media-types.md`:

```markdown
# astromesh-os OCI artifact convention (fixed — changing later is costly)

The image is published to a registry (e.g. Docker Hub) as an **OCI artifact**,
NOT a container image. Consume with `oras pull`, never `docker pull`/`docker run`.

## Tags
- `MAJOR.MINOR.PATCH` (e.g. `0.1.0`) — immutable release.
- `latest` — moves to the newest release.
- Variant suffix (future): `0.1.0-sysext-gpu`.

## Media types
- `application/vnd.astromesh.disk.raw` — the core disk image (`.raw`).
- `application/vnd.astromesh.sysext.<name>` — (reserved) sysext images, later phases.

## Repo
- `docker.io/<org>/astromesh-os` (set via `ORAS_REPO`).
```

- [ ] **Step 4: Verificar**

Run: `bash -n cloud/oras/push.sh && bash -n cloud/oras/pull.sh && echo "oras scripts OK"`
Expected: `oras scripts OK`

- [ ] **Step 5: Hacer ejecutables y commit**

```bash
chmod +x cloud/oras/push.sh cloud/oras/pull.sh
git update-index --chmod=+x cloud/oras/push.sh cloud/oras/pull.sh 2>/dev/null || true
git add cloud/oras/
git commit -m "feat(phase1): ORAS push/pull tooling and fixed media-type scheme"
```

---

## Task 7: Workflow de publicación gateado

**Files:**
- Create: `.github/workflows/phase1-publish.yml`

Se dispara en tag `v*` o `workflow_dispatch`. Reconstruye la imagen (mismos jobs que `phase0-ci`: `build-deb` + `build-image` en contenedor trixie privilegiado, modo `real`), luego publica vía ORAS sólo si hay secret `DOCKERHUB_TOKEN`; sin secret, valida el tooling sin push.

- [ ] **Step 1: Crear el workflow**

Create `.github/workflows/phase1-publish.yml`:

```yaml
name: phase1-publish

on:
  push:
    tags: ["v*"]
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
      - name: Install build deps (inside trixie)
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

  build-image:
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
      - name: Build image (real mode)
        env:
          PHASE0_MODE: real
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        run: mkosi build
      - uses: actions/upload-artifact@v4
        with:
          name: phase1-image
          path: mkosi.output/*.raw

  publish:
    needs: build-image
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: phase1-image
          path: image
      - name: Install ORAS
        run: |
          url=$(curl -sfL https://api.github.com/repos/oras-project/oras/releases/latest \
            | python3 -c "import sys,json; a=json.load(sys.stdin)['assets']; print(next(x['browser_download_url'] for x in a if x['name'].endswith('_linux_amd64.tar.gz')))")
          curl -sfL "$url" -o oras.tgz
          tar -xzf oras.tgz oras
          sudo mv oras /usr/local/bin/oras
          oras version
      - name: Validate ORAS tooling
        run: bash -n cloud/oras/push.sh cloud/oras/pull.sh
      - name: Publish artifact (only with DOCKERHUB_TOKEN)
        env:
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
          ORAS_REPO: docker.io/monaccode/astromesh-os
          ORAS_TAG: ${{ github.ref_type == 'tag' && github.ref_name || 'dev' }}
        run: |
          if [ -z "${DOCKERHUB_TOKEN}" ]; then
            echo "No DOCKERHUB_TOKEN secret — skipping real push (tooling validated)."
            exit 0
          fi
          echo "${DOCKERHUB_TOKEN}" | oras login docker.io -u monaccode --password-stdin
          RAW=$(ls image/*.raw | head -1)
          ORAS_TAG="${ORAS_TAG#v}" bash cloud/oras/push.sh "${RAW}"
```

- [ ] **Step 2: Validar el YAML**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/phase1-publish.yml')); print('workflow OK')"`
Expected: `workflow OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/phase1-publish.yml
git commit -m "ci(phase1): gated ORAS publish workflow (tag/manual + DOCKERHUB_TOKEN)"
```

---

## Task 8: Puesta en verde + loop de recorte (CI)

**Files:** (ninguno nuevo — iteración sobre tamaño/boot/publish)

El gate de tamaño y el boot corren en CI. Esta tarea es el loop medir→recortar→re-validar hasta cumplir el criterio de salida.

- [ ] **Step 1: Pushear la rama y disparar `phase0-ci`**

Push de `feat/phase1`. `phase0-ci` corre (build + boot + el nuevo `mkosi.finalize` gate).
Run: `git push -u origin feat/phase1` luego `gh run watch <run-id> --exit-status`
Expected: `build-deb` y `build-image` corren; `build-image` falla si el rootfs > 500 MB (gate de `mkosi.finalize`) — esperado en la primera vuelta.

- [ ] **Step 2: Leer el desglose de tamaño**

Run: `gh run view <run-id> --log | grep -E '\[finalize\]'`
Expected: el tamaño en MB + el desglose de `/opt/astromesh/venv/.../site-packages/*` ordenado por peso.

- [ ] **Step 3: Recorte dirigido por datos (iterar)**

Con el desglose, identificar deps **opcionales** del runtime que el core no usa (p. ej. clientes de vector stores, RAG, ONNX/GPU si aparecieran) y removerlas en `mkosi.postinst.chroot` (sección 1c) borrando sus directorios concretos en `site-packages`, por ejemplo:

```bash
# Example (only for dirs confirmed present in the [finalize] breakdown and
# confirmed optional — re-run the boot gate after each removal):
rm -rf /opt/astromesh/venv/lib/python*/site-packages/{chromadb,qdrant_client,onnxruntime,faiss}* 2>/dev/null || true
```

Commit cada recorte, re-pushear, y confirmar contra `mkosi.finalize` (tamaño) **y** el boot-gate de `phase0-ci` (que `phase0-smoke` siga respondiendo). Repetir hasta `[finalize] within budget`.

- [ ] **Step 4: Confirmar el criterio de salida**

Expected (spec §8):
- `phase0-ci` verde con `[finalize] within budget (≤500 MB)`.
- El boot-gate sigue pasando (`/v1/health` 200 + `phase0-smoke` responde) sobre la imagen recortada.
- `default.target` = `astromesh-os.target` (verificar en `qemu-console.log`: el boot alcanza el target y `astromeshd` activo).

- [ ] **Step 5: Validar el publish gateado**

Run: `gh workflow run phase1-publish.yml`
Expected: `build-deb`/`build-image`/`publish` en verde; sin `DOCKERHUB_TOKEN`, el step de publish loguea "skipping real push (tooling validated)".

- [ ] **Step 6: Si ≤ 500 MB resulta infactible**

Si tras el recorte razonable el closure de Python no baja de 500 MB sin quitar deps que el core sí usa (boot-gate se rompe), **documentar el tamaño alcanzado + desglose** en el spec (§8 escape hatch) y elevar al usuario la decisión de techo. NO subir `PHASE1_SIZE_BUDGET_MB` en silencio.

- [ ] **Step 7: Cerrar Fase 1**

Tildar la definición de hecho en `docs/superpowers/specs/2026-06-05-phase1-minimal-image-design.md` (§8) y commitear. Siguiente ciclo: **Fase 2** (inmutabilidad: dm-verity, root RO, A/B `sysupdate` + rollback).

---

## Notas de cobertura del spec (self-review)

- §1/§5 Gate de tamaño → Task 1 (`mkosi.finalize`), Task 8 (loop).
- §4.1 Dedup fastapi/uvicorn → Task 2. §4.2 Strip venv → Task 3 + Task 8.3 (deps opcionales). §4.3 Locales/share → Task 4. §4.4 Kernel → ya `linux-image-cloud-amd64` (Fase 0); recorte adicional de módulos queda como dato del desglose si hace falta (Task 8).
- §6 Boot-to-agent target → Task 5. §2 getty conservado → Task 5 (comentario explícito; no se toca `getty@`).
- §7 ORAS → Tasks 6 (tooling) + 7 (workflow). §3/§8 boot-to-agent de Fase 0 como regresión → Task 8 (reusa `phase0-ci`).
- §8 escape hatch (≤500MB infactible) → Task 8.6.
