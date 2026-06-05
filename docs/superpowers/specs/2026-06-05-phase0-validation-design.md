# astromesh-os — Fase 0: Validación del unit (spec)

> **Estado:** Diseño aprobado (2026-06-05)
> **Sub-proyecto:** A (OS Build) — subset mínimo
> **Depende de:** [decomposición](2026-06-05-astromesh-os-decomposition-design.md)
> **Entorno de build:** CI Linux (GitHub Actions, runner Ubuntu); WSL2 para iteración local.

---

## 1. Objetivo y gate

**Objetivo:** probar el *unit* — Astromesh-core corre como systemd service sobre una imagen **mkosi/Debian-trixie estándar**, bootea en QEMU/KVM, y responde **una** query de agente vía API.

**Gate de salida (duro, bloquea el avance a Fase 1):**
1. `GET /v1/health` → **200**.
2. `POST /v1/agents/phase0-smoke/run` (prompt simple) → **respuesta no vacía** (200 + cuerpo con texto del agente).

**Informativo (no bloquea):** `GET /v1/system/doctor` — se loguea; puede reportar `degraded` (ver §7).

---

## 2. Alcance

**Incluido:**
- `mkosi.conf` para una imagen **Debian trixie estándar**, `Format=disk` (qcow2), booteable.
- Instalación de Astromesh-core vía el **`.deb` oficial** (`astromesh-node`) construido desde **fuente pineada** del repo `monaccode/astromesh`.
- Un **agente smoke** (`phase0-smoke`) que usa el provider `openai` (`openai_compat`).
- **Stub OpenAI-compatible** horneado en el guest para el gate hermético de CI.
- Harness de boot+assert en QEMU y dos workflows (CI por push + nightly real).

**NO incluido (queda para Fase 1+):**
- Imagen mínima, recorte agresivo de paquetes, gate de tamaño ≤ 500 MB.
- dm-verity, root read-only, A/B updates, sysext.
- Target boot-to-agent custom (`astromesh-os.target`), generación de `runtime.yaml` por perfil/mesh.
- Cualquier cosa de §12 (diferencial de kernel), seguridad TPM, no-shell.

> **Principio:** Fase 0 se apoya en los artefactos que el runtime **ya provee** (`.deb`, `astromeshd.service`, `postinstall.sh`). No reescribimos ni forkeamos nada del runtime (anti-objetivo D7).

---

## 3. Hechos verificados del runtime (`/d/monaccode/astromesh`)

| Hecho | Ubicación | Implicación para Fase 0 |
|-------|-----------|--------------------------|
| `.deb` `astromesh-node` vía nfpm | `astromesh-node/packaging/{nfpm.yaml, build-deb.sh}` | Instala venv en `/opt/astromesh/venv`, symlinks `astromeshd`/`astromeshctl`, configs en `/etc/astromesh`. |
| `astromeshd.service` (Type=notify, hardened) | `astromesh-node/packaging/systemd/astromeshd.service` | No escribimos el unit. `WantedBy=multi-user.target`. `After=postgresql/redis` es **ordering, no requirement** → no bloquea. |
| `postinstall.sh` hace `systemctl enable astromeshd` (no start) | `astromesh-node/packaging/scripts/postinstall.sh` | El daemon arranca en el primer boot (al alcanzar `multi-user.target`). Crea user/dirs. |
| `GET /v1/health` existe | `astromesh/api/main.py:154` | Gate duro #1 válido. |
| `/v1/system/{status,doctor}` existen | `astromesh/api/routes/system.py` | `doctor.healthy` requiere `provider.health_check()` OK → informativo, no gate. |
| Providers soportados | `astromesh/providers/` + `config/providers.yaml` | `openai` es de tipo **`openai_compat`** (endpoint override-able). **No hay provider Anthropic ni mock.** |
| Agentes de fábrica usan `provider: ollama` | `config/agents/*.agent.yaml` | Ninguno sirve sin ollama/GPU → **necesitamos un agente propio sobre `openai`**. |
| Versión inconsistente (tag local `adk-v0.1.7` vs spec `v0.15.x`) | git | **Pinear ref exacto** en `runtime.pin` (R5). |

---

## 4. Layout del repo (Fase 0)

```
astromesh-os/
├── mkosi.conf                          # Debian trixie, Format=disk/qcow2, bootable
├── mkosi.postinst                      # instala el .deb local; setea agente smoke, providers, .env
├── mkosi.extra/                        # archivos copiados crudos a la imagen (mkosi ExtraTrees)
│   └── etc/astromesh/
│       ├── agents/phase0-smoke.agent.yaml
│       └── providers.yaml              # openai_compat con endpoint parametrizable
├── runtime.pin                         # commit SHA o tag exacto de monaccode/astromesh
├── tests/
│   ├── stub-openai/                    # stub OpenAI-compat (FastAPI/uvicorn mínimo) + unit systemd
│   │   ├── stub_server.py
│   │   └── phase0-stub.service
│   └── boot/
│       └── run-and-assert.sh           # arranca QEMU, hostfwd :8000, curl health+run, asserts
├── .github/workflows/
│   ├── phase0-ci.yml                   # push: build .deb → build imagen (stub) → boot → gate
│   └── phase0-nightly.yml              # nightly: build imagen (real) → boot → query a api.openai.com
└── docs/superpowers/specs/
    ├── 2026-06-05-astromesh-os-decomposition-design.md
    └── 2026-06-05-phase0-validation-design.md   (este)
```

---

## 5. Componentes

### 5.1 `mkosi.conf`
- `[Distribution] Distribution=debian`, `Release=trixie`.
- `[Output] Format=disk`, salida qcow2 (o raw convertible), `Bootable=yes`.
- `[Content]` set **estándar** (NO mínimo todavía): systemd, kernel Debian, `python3.12`/`python3-venv`, `ca-certificates`, `dbus`, `systemd-boot`. El recorte llega en Fase 1.
- `ExtraTrees=mkosi.extra` para inyectar `/etc/astromesh/*`.
- `[Host]` QEMU/virtio para test local.

### 5.2 `mkosi.postinst`
Corre dentro del chroot de la imagen:
1. `dpkg -i` (o `apt-get install ./...`) del `.deb` `astromesh-node` presente en el árbol de build (construido por el Job A de CI, ver §6).
2. Verifica que `postinstall.sh` del `.deb` haya creado user `astromesh`, dirs `/var/lib/astromesh`, y `enable` del service.
3. Asegura que `/etc/astromesh/agents/phase0-smoke.agent.yaml` y `providers.yaml` (de `mkosi.extra`) queden con ownership/perms correctos (`root:astromesh`, `640`).
4. Escribe `/etc/astromesh/.env` (placeholder; el valor real se inyecta por build-arg/secret en §6, no se commitea).

### 5.3 `phase0-smoke.agent.yaml`
Agente mínimo ReAct sobre el provider `openai`:
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
    description: "Minimal agent to validate boot-to-agent over a frontier (openai_compat) provider"
  model:
    primary:
      provider: openai
      model: "gpt-4o-mini"
  prompts:
    system: "You are a smoke-test agent. Answer concisely."
  orchestration:
    pattern: react
    max_iterations: 2
    timeout: 30
```
> El modelo (`gpt-4o-mini`) lo sirve el stub en CI y OpenAI real en nightly — el agente no cambia entre modos; sólo cambia el `endpoint` en `providers.yaml`.

### 5.4 `providers.yaml` (Fase 0)
`openai` de tipo `openai_compat` con `endpoint` parametrizable:
- **CI:** `endpoint: http://127.0.0.1:8081/v1`, `api_key_env: OPENAI_API_KEY` (valor dummy).
- **Nightly:** `endpoint: https://api.openai.com/v1`, `OPENAI_API_KEY` real (Secret).
El postinst (o un drop-in) selecciona la variante según un build-arg `PHASE0_MODE={stub|real}`.

### 5.5 Stub OpenAI-compatible (`tests/stub-openai/`)
- Servidor mínimo (FastAPI+uvicorn, ya en el closure del runtime) que implementa `POST /v1/chat/completions` devolviendo una completion canned determinista.
- `phase0-stub.service`: oneshot/simple systemd unit, `WantedBy=multi-user.target`, `Before=astromeshd.service` (best-effort), escucha en `127.0.0.1:8081`.
- Sólo se hornea cuando `PHASE0_MODE=stub`.

### 5.6 Harness `tests/boot/run-and-assert.sh`
1. Arranca QEMU con la qcow2: `-nic user,hostfwd=tcp::8000-:8000`, KVM si disponible.
2. Poll `http://localhost:8000/v1/health` hasta 200 (timeout ~120s).
3. `POST /v1/agents/phase0-smoke/run` con `{"input":"ping"}` → assert 200 + cuerpo no vacío.
4. `GET /v1/system/doctor` → loguear (informativo).
5. Exit 0 si los asserts duros pasan; apaga el guest.

---

## 6. CI (GitHub Actions)

### `phase0-ci.yml` (en cada push/PR)
- **Job A `build-deb`** (runner Ubuntu): checkout `monaccode/astromesh` al ref de `runtime.pin`; `python3.12` + `uv`; `astromesh-node/packaging/build-deb.sh`; subir el `.deb` como artifact.
- **Job B `build-image`** (needs A): instalar `mkosi` + deps; bajar el `.deb` artifact al árbol de build; `PHASE0_MODE=stub mkosi build`; subir la qcow2 como artifact.
- **Job C `boot-gate`** (needs B): instalar QEMU; `tests/boot/run-and-assert.sh`. Falla el workflow si el gate duro no pasa.

### `phase0-nightly.yml` (cron diario + manual)
- Igual que arriba con `PHASE0_MODE=real`; `OPENAI_API_KEY` desde `secrets`; QEMU con red saliente. Valida la query frontier **real** contra `api.openai.com`. Su fallo **no** bloquea PRs (es señal, no gate de merge).

> **mkosi en CI:** requiere privilegios (loop devices). Usar runner Ubuntu con `sudo`; documentar los flags (`--debug`, `ToolsTree` si hace falta) en el workflow.

---

## 7. Riesgos y mitigaciones (Fase 0)

| ID | Riesgo | Mitigación |
|----|--------|-----------|
| P0-1 | **mkosi necesita privilegios** en CI (loop/dm). | Runner Ubuntu con `sudo`; fijar versión de mkosi; fallback a `ToolsTree`/contenedor privilegiado si el runner lo limita. |
| P0-2 | **`doctor` da `degraded`** porque el stub no implementa `health_check` del provider. | Gate duro NO depende de `doctor`. Opcional: el stub implementa un `/v1/models` o health trivial para que dé `ok`. |
| P0-3 | **Ref del runtime inconsistente** (R5 global). | `runtime.pin` con SHA exacto; CI falla si no resuelve. Documentar cómo bumpearlo. |
| P0-4 | **`After=postgresql/redis`** podría sugerir dependencias. | Es ordering, no `Requires`; verificar en el primer boot que `astromeshd` queda `active` sin esos servicios. Si el bootstrap del runtime exige redis/postgres para `health`, evaluar `runtime.yaml` con memoria SQLite (default mínimo del spec) — confirmar en el primer boot. |
| P0-5 | **Red saliente desde QEMU en nightly.** | User-mode networking (SLIRP) da NAT saliente por default; sólo el nightly lo necesita. |
| P0-6 | **Costo/flakiness de la query real.** | Aislada en nightly, no en el gate de merge; `gpt-4o-mini`, `max_iterations: 2`. |

---

## 8. Definición de "hecho" (Fase 0) — ✅ CUMPLIDA (2026-06-05)

- [x] `phase0-ci.yml` verde: imagen booteable + `/v1/health` 200 + `phase0-smoke` responde (vía stub). *(run 27027974832; agente devolvió `{"answer":"pong"}` vía provider `openai_compat`→stub `gpt-4o-mini`).*
- [ ] `phase0-nightly.yml` verde al menos una vez: misma cadena contra OpenAI real. *(Pendiente: requiere el secret `OPENAI_API_KEY`; diferido por decisión del usuario — el workflow existe y está listo).*
- [x] `runtime.pin` fija un SHA exacto y CI lo resuelve. *(`ASTROMESH_REF=d83e36a…`; build del `.deb` `astromesh-node_0.1.1`).*
- [x] Primer boot confirmado: `astromeshd` queda `active` y sirve `:8000` sin postgres/redis. *(arranca en "dev mode", carga 7 agentes, `Notified systemd: READY`).*
- [x] Documentado cómo correr el build localmente. *(README: build vía contenedor Docker — no hay distro WSL general en el host).*

### Aprendizajes de la primera puesta en verde de CI (20 iteraciones)
El gate hermético requirió resolver, en orden: shell `bash` en contenedor; resolver el asset `.deb` de nfpm por API; bit `+x` de scripts en git (Windows); `Bootable` en `[Content]`; **build del `.deb` y de la imagen en contenedor `debian:trixie` privilegiado** (la mkosi del apt de Ubuntu es muy vieja para trixie — nombres de paquetes de initrd obsoletos, ignora `ToolsTree`); imagen mínima sin `apt`→`dpkg -i`; sin `passwd`→agregarlo; `systemctl` del `.deb` postinst neutralizado en el chroot de build; stub vía paquetes apt (`python3-fastapi`/`uvicorn`) por falta de red en postinst; kernel `linux-image-cloud-amd64`; `OutputDirectory` explícito; **boot UEFI con OVMF (pflash)** + `chmod 666 /dev/kvm`; **shebangs del venv reubicado reescritos** (203/EXEC); **DHCP en la NIC** + **drop-in `WatchdogSec=0`** (el daemon no manda `WATCHDOG=1`). Estos son insumos directos para Fase 1 (imagen mínima) y para reportar fricciones de empaquetado al runtime.

Cumplido el gate → siguiente ciclo: brainstorm→spec→plan de **Fase 1** (imagen mínima + boot-to-agent + gate ≤ 500 MB + publicación ORAS).
