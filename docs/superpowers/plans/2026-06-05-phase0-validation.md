# astromesh-os Fase 0 (Validación del unit) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir una imagen mkosi/Debian-trixie estándar que corra Astromesh-core como systemd service, bootee en QEMU y responda una query de agente vía API, validada por un gate de CI hermético.

**Architecture:** La imagen instala el `.deb` oficial `astromesh-node` (construido desde una fuente pineada del repo `monaccode/astromesh`) — que ya trae `astromeshd` + `astromeshctl` + el unit systemd. astromesh-os sólo aporta: config de imagen (`mkosi.conf`/`postinst`), un agente smoke sobre el provider `openai_compat`, un stub OpenAI-compatible para el gate hermético, un harness de boot en QEMU, y los workflows de CI. No se forkea ni reescribe nada del runtime.

**Tech Stack:** mkosi, Debian trixie, systemd, QEMU/KVM, Python 3.12 (FastAPI/uvicorn para el stub), GitHub Actions, uv.

**Spec:** `docs/superpowers/specs/2026-06-05-phase0-validation-design.md`

**Restricción de entorno:** el host de desarrollo es Windows; mkosi/QEMU son Linux-only. La verificación autoritativa corre en **CI Linux**. Localmente se itera vía **contenedor Docker privilegiado** (hay Docker; no hay distro WSL general). Las verificaciones host-runnable de este plan (pytest del stub, `bash -n`, `python -c yaml.safe_load`) se ejecutan con el Git-Bash/uv del host.

---

## File Structure

| Archivo | Responsabilidad |
|---------|-----------------|
| `runtime.pin` | SHA/tag exacto de `monaccode/astromesh` a construir (reproducibilidad). |
| `mkosi.conf` | Config de imagen: Debian trixie, qcow2 booteable, ExtraTrees, Environment. |
| `mkosi.postinst` | Dentro del chroot: instala el `.deb`, selecciona providers por `PHASE0_MODE`, escribe `.env`, habilita el stub en modo stub. |
| `mkosi.extra/etc/astromesh/agents/phase0-smoke.agent.yaml` | Agente mínimo ReAct sobre provider `openai`. |
| `mkosi.extra/etc/astromesh/providers.stub.yaml` | Variante de providers apuntando al stub local. |
| `mkosi.extra/etc/astromesh/providers.real.yaml` | Variante apuntando a `api.openai.com`. |
| `tests/stub-openai/stub_server.py` | Stub OpenAI-compatible (chat/completions + models). |
| `tests/stub-openai/test_stub_server.py` | Tests del stub (host-runnable). |
| `tests/stub-openai/phase0-stub.service` | Unit systemd del stub (sólo modo stub). |
| `tests/boot/run-and-assert.sh` | Arranca QEMU, port-forward :8000, curl health + run, asserts. |
| `.github/workflows/phase0-ci.yml` | Gate por push: build .deb → build imagen (stub) → boot → assert. |
| `.github/workflows/phase0-nightly.yml` | Nightly: build imagen (real) → boot → query a OpenAI real. |
| `README.md` | Intro + cómo buildear local vía Docker + cómo bumpear `runtime.pin`. |
| `.gitignore` | Ignora artefactos de build (`*.qcow2`, `*.raw`, `*.deb`, `.mkosi-*`, venvs). |

---

## Task 1: Scaffolding del repo

**Files:**
- Create: `.gitignore`
- Create: `runtime.pin`
- Create: `README.md`

- [ ] **Step 1: Crear `.gitignore`**

```gitignore
# Build artifacts
*.qcow2
*.raw
*.deb
*.img
mkosi.output/
mkosi.cache/
mkosi.builddir/
.mkosi-*

# Python
__pycache__/
*.pyc
.venv/
.pytest_cache/

# Local secrets
*.env
!*.env.example
```

- [ ] **Step 2: Crear `runtime.pin`**

Resolver el SHA actual del repo runtime y fijarlo. Determinar el valor:

Run: `git -C /d/monaccode/astromesh rev-parse HEAD`
Expected: imprime un SHA de 40 chars.

Crear `runtime.pin` con ese SHA (una línea, sin newline extra). Formato:

```
# Pinned ref of github.com/monaccode/astromesh built into the Phase 0 image.
# Bump deliberately; CI fails if it cannot resolve this ref.
ASTROMESH_REF=<SHA-de-40-chars>
```

- [ ] **Step 3: Crear `README.md`**

```markdown
# astromesh-os

Minimal, immutable, API-only Linux distribution (appliance) whose sole purpose is
running Astromesh AI agents (`astromeshd`). See the design docs in
`docs/superpowers/specs/`.

## Status: Fase 0 (validación del unit)

Phase 0 builds a **standard** Debian-trixie mkosi image that runs Astromesh-core as a
systemd service and answers one agent query. It is intentionally NOT minimal/immutable
yet — that is Fase 1+.

## Build (local, vía Docker)

mkosi and QEMU are Linux-only. On Windows/macOS, build inside a privileged Debian
container:

\`\`\`bash
docker run --rm -it --privileged -v "$PWD":/work -w /work debian:trixie bash
# inside the container:
apt-get update && apt-get install -y mkosi qemu-system-x86 git python3 python3-pip
# build the runtime .deb first (see .github/workflows/phase0-ci.yml), then:
PHASE0_MODE=stub mkosi build
\`\`\`

CI (GitHub Actions) is the authoritative gate: see `.github/workflows/phase0-ci.yml`.

## Bumping the runtime version

Edit `ASTROMESH_REF` in `runtime.pin` to a new commit SHA of `monaccode/astromesh`,
then re-run CI. The image is reproducible from that exact ref.
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore runtime.pin README.md
git commit -m "chore: scaffold astromesh-os repo for Phase 0"
```

---

## Task 2: Stub OpenAI-compatible (TDD, host-runnable)

**Files:**
- Create: `tests/stub-openai/stub_server.py`
- Test: `tests/stub-openai/test_stub_server.py`

El stub deja el gate de CI hermético: el provider `openai_compat` del agente apunta a este servidor en vez de a OpenAI. Implementa lo mínimo que el provider toca: `POST /v1/chat/completions` (la query) y `GET /v1/models` (para que `doctor`/health no quede en error).

- [ ] **Step 1: Escribir los tests que fallan**

Create `tests/stub-openai/test_stub_server.py`:

```python
"""Tests for the Phase 0 OpenAI-compatible stub."""

from fastapi.testclient import TestClient

from stub_server import app

client = TestClient(app)


def test_models_lists_gpt4o_mini():
    resp = client.get("/v1/models")
    assert resp.status_code == 200
    ids = [m["id"] for m in resp.json()["data"]]
    assert "gpt-4o-mini" in ids


def test_chat_completions_returns_canned_content():
    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "gpt-4o-mini",
            "messages": [{"role": "user", "content": "ping"}],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["model"] == "gpt-4o-mini"
    assert body["choices"][0]["message"]["content"] == "pong"
    assert body["choices"][0]["finish_reason"] == "stop"


def test_chat_completions_is_deterministic():
    payload = {
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "anything"}],
    }
    first = client.post("/v1/chat/completions", json=payload).json()
    second = client.post("/v1/chat/completions", json=payload).json()
    assert first["choices"][0]["message"]["content"] == second["choices"][0]["message"]["content"]
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd tests/stub-openai && uv run --with fastapi --with httpx --with pytest pytest -v`
Expected: FAIL con `ModuleNotFoundError: No module named 'stub_server'`.

- [ ] **Step 3: Implementar el stub**

Create `tests/stub-openai/stub_server.py`:

```python
"""Minimal OpenAI-compatible stub for Phase 0 hermetic CI.

Serves just enough of the OpenAI API for the `openai_compat` provider:
- POST /v1/chat/completions  -> deterministic canned completion ("pong")
- GET  /v1/models            -> lists gpt-4o-mini so provider health passes

Run standalone:
    uvicorn stub_server:app --host 127.0.0.1 --port 8081
"""

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="phase0-openai-stub")


class Message(BaseModel):
    role: str
    content: str | None = None


class ChatRequest(BaseModel):
    model: str
    messages: list[Message]


@app.get("/v1/models")
def list_models() -> dict:
    return {
        "object": "list",
        "data": [{"id": "gpt-4o-mini", "object": "model", "owned_by": "stub"}],
    }


@app.post("/v1/chat/completions")
def chat_completions(req: ChatRequest) -> dict:
    return {
        "id": "chatcmpl-phase0-stub",
        "object": "chat.completion",
        "created": 0,
        "model": req.model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "pong"},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }
```

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `cd tests/stub-openai && uv run --with fastapi --with httpx --with pytest pytest -v`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add tests/stub-openai/stub_server.py tests/stub-openai/test_stub_server.py
git commit -m "feat: add OpenAI-compatible stub for Phase 0 hermetic gate"
```

---

## Task 3: Agente smoke + variantes de providers

**Files:**
- Create: `mkosi.extra/etc/astromesh/agents/phase0-smoke.agent.yaml`
- Create: `mkosi.extra/etc/astromesh/providers.stub.yaml`
- Create: `mkosi.extra/etc/astromesh/providers.real.yaml`

- [ ] **Step 1: Crear el agente smoke**

Create `mkosi.extra/etc/astromesh/agents/phase0-smoke.agent.yaml`:

```yaml
apiVersion: astromesh/v1
kind: Agent
metadata:
  name: phase0-smoke
  version: "0.0.1"
  namespace: system
spec:
  identity:
    display_name: "Phase 0 Smoke Agent"
    description: "Minimal agent to validate boot-to-agent over an openai_compat provider"
  model:
    primary:
      provider: openai
      model: "gpt-4o-mini"
      parameters:
        temperature: 0.0
        max_tokens: 64
  prompts:
    system: "You are a smoke-test agent. Answer concisely."
  orchestration:
    pattern: react
    max_iterations: 2
    timeout: 30
```

- [ ] **Step 2: Crear la variante stub de providers**

Create `mkosi.extra/etc/astromesh/providers.stub.yaml`:

```yaml
apiVersion: astromesh/v1
kind: ProviderConfig
metadata:
  name: default-providers
spec:
  providers:
    openai:
      type: openai_compat
      endpoint: "http://127.0.0.1:8081/v1"
      api_key_env: OPENAI_API_KEY
      models:
        - "gpt-4o-mini"
      health_check_interval: 30
  routing:
    default_strategy: cost_optimized
    fallback_enabled: false
```

- [ ] **Step 3: Crear la variante real de providers**

Create `mkosi.extra/etc/astromesh/providers.real.yaml`:

```yaml
apiVersion: astromesh/v1
kind: ProviderConfig
metadata:
  name: default-providers
spec:
  providers:
    openai:
      type: openai_compat
      endpoint: "https://api.openai.com/v1"
      api_key_env: OPENAI_API_KEY
      models:
        - "gpt-4o-mini"
      health_check_interval: 30
  routing:
    default_strategy: cost_optimized
    fallback_enabled: false
```

- [ ] **Step 4: Verificar que los YAML son válidos y bien formados**

Run:
```bash
python -c "import yaml,sys; [print(f,'OK') or yaml.safe_load(open(f)) for f in ['mkosi.extra/etc/astromesh/agents/phase0-smoke.agent.yaml','mkosi.extra/etc/astromesh/providers.stub.yaml','mkosi.extra/etc/astromesh/providers.real.yaml']]"
```
Expected: las 3 líneas terminan en `OK`, sin excepción. Verificar también que el agente tiene `kind: Agent` y `spec.model.primary.provider: openai`.

- [ ] **Step 5: Commit**

```bash
git add mkosi.extra/etc/astromesh/
git commit -m "feat: add phase0-smoke agent and stub/real provider variants"
```

---

## Task 4: Unit systemd del stub

**Files:**
- Create: `tests/stub-openai/phase0-stub.service`

- [ ] **Step 1: Crear el unit del stub**

Create `tests/stub-openai/phase0-stub.service`:

```ini
[Unit]
Description=Phase 0 OpenAI-compatible stub
Documentation=https://github.com/monaccode/astromesh-os
Before=astromeshd.service
Wants=network.target
After=network.target

[Service]
Type=simple
ExecStart=/opt/phase0-stub/venv/bin/uvicorn stub_server:app --host 127.0.0.1 --port 8081
WorkingDirectory=/opt/phase0-stub
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Verificar la sintaxis del unit**

Run: `python -c "import configparser; c=configparser.ConfigParser(strict=False); c.read('tests/stub-openai/phase0-stub.service'); assert 'Service' in c and 'ExecStart' in c['Service']; print('unit OK')"`
Expected: `unit OK`.

- [ ] **Step 3: Commit**

```bash
git add tests/stub-openai/phase0-stub.service
git commit -m "feat: add systemd unit for the Phase 0 stub"
```

---

## Task 5: `mkosi.conf`

**Files:**
- Create: `mkosi.conf`

- [ ] **Step 1: Crear `mkosi.conf`**

Create `mkosi.conf`:

```ini
[Distribution]
Distribution=debian
Release=trixie

[Output]
Format=disk
CompressOutput=no
Bootable=yes
ImageId=astromesh-os-phase0

[Content]
Bootloader=systemd-boot
Packages=
        systemd
        systemd-boot
        udev
        dbus
        ca-certificates
        python3
        python3-venv
        libpython3.12
        iproute2
        curl
Environment=PHASE0_MODE
RootPassword=hashed:!

[Runtime]
# Local `mkosi qemu` test settings (CI drives QEMU directly via tests/boot).
RAM=2G
CPUs=2

[Build]
# Extra files (agents, providers, stub payload) are injected via mkosi.extra/
# which mkosi picks up as an ExtraTree by convention.
```

> Nota: `Environment=PHASE0_MODE` propaga la variable del host (export `PHASE0_MODE=stub|real`) hacia `mkosi.postinst`. `mkosi.extra/` se monta como ExtraTree por convención de mkosi (su contenido se copia a la raíz de la imagen).

- [ ] **Step 2: Verificar que el INI parsea**

Run: `python -c "import configparser; c=configparser.ConfigParser(strict=False, allow_no_value=True); c.read('mkosi.conf'); assert c['Distribution']['Distribution']=='debian'; print('mkosi.conf OK')"`
Expected: `mkosi.conf OK`.

- [ ] **Step 3: Commit**

```bash
git add mkosi.conf
git commit -m "feat: add mkosi.conf for standard Debian trixie Phase 0 image"
```

---

## Task 6: `mkosi.postinst`

**Files:**
- Create: `mkosi.postinst`

Corre dentro del chroot de la imagen al final de la instalación de paquetes. Instala el `.deb` (que CI deja en `$BUILDROOT`/contexto), selecciona la variante de providers según `PHASE0_MODE`, escribe `/etc/astromesh/.env`, y en modo stub instala el payload + unit del stub.

- [ ] **Step 1: Crear `mkosi.postinst`**

Create `mkosi.postinst`:

```bash
#!/usr/bin/env bash
# Runs inside the image chroot after package installation.
set -euo pipefail

MODE="${PHASE0_MODE:-stub}"
ETC="/etc/astromesh"
echo "[postinst] PHASE0_MODE=${MODE}"

# 1. Install the astromesh-node .deb staged into the image tree at /opt/astromesh-staging
#    (CI copies it there via mkosi.extra/ before the build; see Task 8).
STAGING="/opt/astromesh-staging"
DEB=$(ls "${STAGING}"/astromesh-node_*_amd64.deb 2>/dev/null | head -1 || true)
if [ -z "${DEB}" ]; then
    echo "[postinst] ERROR: astromesh-node .deb not found in ${STAGING}"
    exit 1
fi
echo "[postinst] Installing ${DEB}"
apt-get install -y "${DEB}"

# 2. Select providers variant.
if [ "${MODE}" = "real" ]; then
    install -m 0640 "${ETC}/providers.real.yaml" "${ETC}/providers.yaml"
else
    install -m 0640 "${ETC}/providers.stub.yaml" "${ETC}/providers.yaml"
fi

# 3. Write /etc/astromesh/.env (consumed by astromeshd.service EnvironmentFile).
#    In stub mode the key is a dummy. In real mode, CI passes OPENAI_API_KEY via env.
echo "OPENAI_API_KEY=${OPENAI_API_KEY:-sk-phase0-stub-dummy}" > "${ETC}/.env"
chmod 0640 "${ETC}/.env"
chown root:astromesh "${ETC}/.env" "${ETC}/providers.yaml"

# 4. Stub payload + service, only in stub mode.
if [ "${MODE}" = "stub" ]; then
    echo "[postinst] Installing Phase 0 stub"
    python3 -m venv /opt/phase0-stub/venv
    /opt/phase0-stub/venv/bin/pip install --quiet --no-cache-dir fastapi uvicorn
    install -m 0644 "${STAGING}/stub_server.py" /opt/phase0-stub/stub_server.py
    install -m 0644 "${STAGING}/phase0-stub.service" /etc/systemd/system/phase0-stub.service
    systemctl enable phase0-stub.service
fi

# 5. Ensure astromeshd is enabled (the .deb postinstall already does this; idempotent).
systemctl enable astromeshd.service

# 6. Remove the staging dir so it does not ship in the image.
rm -rf "${STAGING}"

echo "[postinst] done (mode=${MODE})"
```

- [ ] **Step 2: Verificar la sintaxis bash**

Run: `bash -n mkosi.postinst && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 3: Hacerlo ejecutable y commit**

```bash
chmod +x mkosi.postinst
git add mkosi.postinst
git commit -m "feat: add mkosi.postinst to install .deb, select providers, stage stub"
```

---

## Task 7: Harness de boot `run-and-assert.sh`

**Files:**
- Create: `tests/boot/run-and-assert.sh`

- [ ] **Step 1: Crear el harness**

Create `tests/boot/run-and-assert.sh`:

```bash
#!/usr/bin/env bash
# Boots the Phase 0 qcow2 in QEMU and asserts the boot-to-agent gate.
# Usage: tests/boot/run-and-assert.sh <path-to-disk-image>
set -euo pipefail

IMAGE="${1:?usage: run-and-assert.sh <disk-image>}"
PORT=8000
BOOT_TIMEOUT=180
AGENT="phase0-smoke"

KVM_FLAG=""
if [ -e /dev/kvm ]; then KVM_FLAG="-enable-kvm"; fi

echo "[boot] starting QEMU (image=${IMAGE}, kvm=${KVM_FLAG:-none})"
qemu-system-x86_64 \
    ${KVM_FLAG} \
    -m 2048 -smp 2 \
    -nographic \
    -drive file="${IMAGE}",format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${PORT}-:${PORT} \
    > qemu-console.log 2>&1 &
QEMU_PID=$!
trap 'kill ${QEMU_PID} 2>/dev/null || true' EXIT

echo "[boot] waiting for /v1/health (timeout ${BOOT_TIMEOUT}s)"
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until curl -fsS "http://localhost:${PORT}/v1/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "[boot] FAIL: /v1/health did not respond in time"
        echo "----- qemu-console.log (tail) -----"; tail -n 60 qemu-console.log || true
        exit 1
    fi
    sleep 3
done
echo "[boot] PASS: /v1/health is 200"

echo "[boot] running agent ${AGENT}"
RESP=$(curl -fsS -X POST "http://localhost:${PORT}/v1/agents/${AGENT}/run" \
    -H 'Content-Type: application/json' \
    -d '{"input":"ping"}')
echo "[boot] agent response: ${RESP}"
if [ -z "${RESP}" ]; then
    echo "[boot] FAIL: empty agent response"
    exit 1
fi
echo "[boot] PASS: agent returned a non-empty response"

echo "[boot] doctor (informational):"
curl -fsS "http://localhost:${PORT}/v1/system/doctor" || echo "[boot] (doctor unavailable)"

echo "[boot] GATE PASSED"
```

- [ ] **Step 2: Verificar la sintaxis bash**

Run: `bash -n tests/boot/run-and-assert.sh && echo "syntax OK"`
Expected: `syntax OK`.

> Nota: el endpoint exacto de ejecución (`POST /v1/agents/<name>/run` y la key `input` del body) debe confirmarse contra `astromesh/api/routes/agents.py` durante la ejecución; si difiere, ajustar el curl y el assert. El gate duro es: 200 + cuerpo no vacío.

- [ ] **Step 3: Hacerlo ejecutable y commit**

```bash
chmod +x tests/boot/run-and-assert.sh
git add tests/boot/run-and-assert.sh
git commit -m "feat: add QEMU boot-and-assert harness for Phase 0 gate"
```

---

## Task 8: Workflow CI `phase0-ci.yml`

**Files:**
- Create: `.github/workflows/phase0-ci.yml`

- [ ] **Step 1: Confirmar el contrato de build del runtime**

Antes de escribir el workflow, confirmar el script y la salida del `.deb`:

Run: `sed -n '1,40p' /d/monaccode/astromesh/astromesh-node/packaging/build-deb.sh`
Expected: confirma que produce `dist/astromesh-node_<version>_amd64.deb` y que usa `python3 -m venv` + `pip install ../ ".[systemd]"` + `nfpm`.

- [ ] **Step 2: Crear el workflow**

Create `.github/workflows/phase0-ci.yml`:

```yaml
name: phase0-ci

on:
  push:
  pull_request:

jobs:
  build-deb:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout astromesh-os
        uses: actions/checkout@v4
      - name: Read pinned runtime ref
        id: pin
        run: |
          source runtime.pin
          echo "ref=${ASTROMESH_REF}" >> "$GITHUB_OUTPUT"
      - name: Checkout astromesh runtime at pinned ref
        uses: actions/checkout@v4
        with:
          repository: monaccode/astromesh
          ref: ${{ steps.pin.outputs.ref }}
          path: _runtime
      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install nfpm
        run: |
          curl -sfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o nfpm.deb
          sudo apt-get install -y ./nfpm.deb
      - name: Build .deb
        working-directory: _runtime/astromesh-node
        run: bash packaging/build-deb.sh
      - name: Stage .deb for image build
        run: |
          mkdir -p dist
          cp _runtime/astromesh-node/dist/astromesh-node_*_amd64.deb dist/
      - name: Upload .deb
        uses: actions/upload-artifact@v4
        with:
          name: astromesh-deb
          path: dist/*.deb

  build-image:
    needs: build-deb
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Download .deb
        uses: actions/download-artifact@v4
        with:
          name: astromesh-deb
          path: dist
      - name: Install mkosi
        run: |
          sudo apt-get update
          sudo apt-get install -y mkosi systemd-container qemu-utils
      - name: Stage payload into image tree (mkosi.extra)
        run: |
          mkdir -p mkosi.extra/opt/astromesh-staging
          cp dist/astromesh-node_*_amd64.deb mkosi.extra/opt/astromesh-staging/
          cp tests/stub-openai/stub_server.py tests/stub-openai/phase0-stub.service mkosi.extra/opt/astromesh-staging/
      - name: Build image (stub mode)
        env:
          PHASE0_MODE: stub
        run: sudo --preserve-env=PHASE0_MODE mkosi build
      - name: Upload disk image
        uses: actions/upload-artifact@v4
        with:
          name: phase0-image
          path: mkosi.output/*.raw

  boot-gate:
    needs: build-image
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Download disk image
        uses: actions/download-artifact@v4
        with:
          name: phase0-image
          path: image
      - name: Install QEMU + curl
        run: sudo apt-get update && sudo apt-get install -y qemu-system-x86 curl qemu-utils
      - name: Convert raw to qcow2
        run: qemu-img convert -O qcow2 image/*.raw phase0.qcow2
      - name: Run boot gate
        run: bash tests/boot/run-and-assert.sh phase0.qcow2
```

> Notas a confirmar en ejecución: (a) la extensión real de salida de mkosi (`.raw` vs otra) según versión — ajustar el glob; (b) si mkosi en el runner necesita `ToolsTree` o flags extra (P0-1), agregarlos acá; (c) `KVM` puede no estar en runners hosteados → el harness corre sin `-enable-kvm` (más lento pero funciona).

- [ ] **Step 3: Validar el YAML del workflow**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/phase0-ci.yml')); print('workflow YAML OK')"`
Expected: `workflow YAML OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/phase0-ci.yml
git commit -m "ci: add Phase 0 hermetic gate (build deb, build image, boot assert)"
```

---

## Task 9: Workflow nightly `phase0-nightly.yml`

**Files:**
- Create: `.github/workflows/phase0-nightly.yml`

- [ ] **Step 1: Crear el workflow nightly**

Create `.github/workflows/phase0-nightly.yml`:

```yaml
name: phase0-nightly

on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:

jobs:
  build-deb:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - id: pin
        run: |
          source runtime.pin
          echo "ref=${ASTROMESH_REF}" >> "$GITHUB_OUTPUT"
      - uses: actions/checkout@v4
        with:
          repository: monaccode/astromesh
          ref: ${{ steps.pin.outputs.ref }}
          path: _runtime
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install nfpm
        run: |
          curl -sfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o nfpm.deb
          sudo apt-get install -y ./nfpm.deb
      - name: Build .deb
        working-directory: _runtime/astromesh-node
        run: bash packaging/build-deb.sh
      - run: mkdir -p dist && cp _runtime/astromesh-node/dist/astromesh-node_*_amd64.deb dist/
      - uses: actions/upload-artifact@v4
        with:
          name: astromesh-deb
          path: dist/*.deb

  build-image-real:
    needs: build-deb
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: astromesh-deb
          path: dist
      - name: Install mkosi
        run: sudo apt-get update && sudo apt-get install -y mkosi systemd-container qemu-utils
      - name: Stage payload into image tree (mkosi.extra)
        run: |
          mkdir -p mkosi.extra/opt/astromesh-staging
          cp dist/astromesh-node_*_amd64.deb mkosi.extra/opt/astromesh-staging/
          cp tests/stub-openai/stub_server.py tests/stub-openai/phase0-stub.service mkosi.extra/opt/astromesh-staging/
      - name: Build image (real mode)
        env:
          PHASE0_MODE: real
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        run: sudo --preserve-env=PHASE0_MODE,OPENAI_API_KEY mkosi build
      - uses: actions/upload-artifact@v4
        with:
          name: phase0-image-real
          path: mkosi.output/*.raw

  boot-gate-real:
    needs: build-image-real
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: phase0-image-real
          path: image
      - name: Install QEMU + curl
        run: sudo apt-get update && sudo apt-get install -y qemu-system-x86 curl qemu-utils
      - run: qemu-img convert -O qcow2 image/*.raw phase0.qcow2
      - name: Run boot gate against real OpenAI
        run: bash tests/boot/run-and-assert.sh phase0.qcow2
```

> El secreto `OPENAI_API_KEY` debe configurarse en el repo (Settings → Secrets). El fallo de este workflow es **señal**, no gate de merge.

- [ ] **Step 2: Validar el YAML**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/phase0-nightly.yml')); print('nightly YAML OK')"`
Expected: `nightly YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/phase0-nightly.yml
git commit -m "ci: add Phase 0 nightly gate against real OpenAI frontier"
```

---

## Task 10: Primera corrida verde + cierre del gate

**Files:** (ninguno nuevo — verificación end-to-end y ajustes)

- [ ] **Step 1: Crear el repo remoto y pushear**

Crear el repo `monaccode/astromesh-os` en GitHub (o el remoto que corresponda), agregar `origin`, y pushear `main`. Confirmar con el usuario el nombre/owner antes de crear nada remoto.

Run: `git remote -v`
Expected: `origin` apunta al remoto correcto.

- [ ] **Step 2: Disparar `phase0-ci` y leer el resultado**

Push dispara `phase0-ci`. Observar los 3 jobs.
Run: `gh run watch` (o `gh run list --workflow phase0-ci.yml`)
Expected: `build-deb`, `build-image`, `boot-gate` en verde.

- [ ] **Step 3: Iterar sobre los fallos esperados (P0-1..P0-4)**

Para cada fallo, diagnosticar contra los riesgos del spec:
- **P0-1 (privilegios mkosi):** si `mkosi build` falla por loop/dm, agregar flags/`ToolsTree` o un contenedor privilegiado en el job.
- **P0-4 (bootstrap exige redis/postgres):** si `astromeshd` no llega a `active`, inspeccionar `qemu-console.log`; confirmar que `runtime.yaml` usa memoria SQLite (default mínimo) y que no hay `Requires=` sobre redis/postgres. Ajustar `runtime.yaml` horneado si hace falta (vía `mkosi.extra/etc/astromesh/runtime.yaml`).
- **Endpoint del agente:** si el `run` da 404/422, confirmar la ruta/payload reales en `_runtime` (`astromesh/api/routes/agents.py`) y ajustar `run-and-assert.sh`.
Commitear cada ajuste con mensaje descriptivo y re-disparar.

- [ ] **Step 4: Confirmar el gate de Fase 0**

Expected (definición de "hecho" del spec):
- `phase0-ci` verde: imagen booteable + `/v1/health` 200 + `phase0-smoke` responde (vía stub).
- `astromeshd` queda `active` sin postgres/redis (confirmado en `qemu-console.log`).

- [ ] **Step 5: Disparar el nightly una vez (manual) y confirmar la query real**

Run: `gh workflow run phase0-nightly.yml`
Expected: `boot-gate-real` verde — la query real a `api.openai.com` devuelve respuesta no vacía. (Requiere el Secret `OPENAI_API_KEY`.)

- [ ] **Step 6: Marcar Fase 0 cerrada**

Actualizar el estado en `docs/superpowers/specs/2026-06-05-phase0-validation-design.md` (§8) tildando la definición de hecho, y commitear. Siguiente ciclo: brainstorm→spec→plan de **Fase 1**.

---

## Notas de cobertura del spec (self-review)

- §1 Gate (health 200 + agente responde) → Tasks 7, 10.
- §2 Alcance (imagen estándar, no mínima) → Task 5 (paquetes estándar, sin gate de tamaño).
- §3 Hechos del runtime (.deb, unit, /v1/health, providers, agentes ollama) → Tasks 6, 8 (build .deb), 3 (agente openai propio).
- §4 Layout → Tasks 1–9 cubren cada archivo.
- §5.1 mkosi.conf → Task 5. §5.2 postinst → Task 6. §5.3 agente → Task 3. §5.4 providers → Task 3. §5.5 stub → Tasks 2,4. §5.6 harness → Task 7.
- §6 CI (ci + nightly) → Tasks 8, 9. §7 Riesgos P0-1..6 → Task 10 (iteración) + notas inline. §8 Definición de hecho → Task 10.
