# astromesh-os — Diseño de decomposición y roadmap

> **Estado:** Diseño aprobado (2026-06-05)
> **Tipo:** Documento de arquitectura + decomposición. **No es** un plan de implementación.
> **Fuente:** "Astromesh OS — Especificación de Construcción" v1.0.
> **Alcance de este doc:** resolver las `[DECISIÓN HUMANA]` abiertas, descomponer el spec en sub-proyectos independientes y secuenciarlos. El build NO se construye en esta sesión.

---

## 0. Propósito

El spec v1.0 describe un **programa de varios proyectos**, no un proyecto único: build de un OS, inmutabilidad/updates, plano de control, seguridad, sandboxing, un diferencial de kernel (§12, 6–7 componentes Rust+eBPF) y distribución multi-cloud. No cabe en un solo ciclo spec→plan→implementación.

Este documento:
1. Cierra las decisiones humanas abiertas (sección 2, formato ADR).
2. Descompone el spec en **7 sub-proyectos independientes** (sección 3).
3. Los **secuencia** en el roadmap por fases del spec, con gates de salida (sección 4).
4. Enumera **riesgos y mitigaciones** (sección 5).
5. Define el **siguiente paso**: brainstorm→spec→plan de Fase 0 (sección 6).

**Regla transversal heredada del spec:** no se avanza de fase N+1 hasta que la fase N bootee y pase sus checks.

---

## 1. Contexto verificado

- El runtime **`astromesh`** existe como repo hermano (`/d/monaccode/astromesh`). Confirmado contra el código:
  - Los **7 perfiles** del spec están en `config/profiles/`: `full`, `gateway`, `inference`, `worker`, `mesh-gateway`, `mesh-inference`, `mesh-worker`. No existe `mesh-full` (la malla exige separación de roles).
  - Usa `pyproject.toml` (Python) + `Cargo.toml` (extensiones Rust). Tiene `Dockerfile`, `config/`, `deploy/`.
  - El tag local visible es `adk-v0.1.7-12-g…`; el spec referencia `v0.15.x`. **Discrepancia de versión a resolver al pinear** (ver Riesgo R5).
- **Host de desarrollo: Windows 11 (MINGW64)**. No hay `mkosi`. Sí hay **WSL2, Docker y `cargo`**. Todo el toolchain de build del OS (mkosi, QEMU/KVM, dm-verity, eBPF, `sched_ext`, CRIU) es **Linux-only**.
- **Entorno de build elegido:** CI Linux (GitHub Actions); WSL2 para iteración local.

---

## 2. Decisiones resueltas (ADRs)

Las decisiones cerradas del spec (D1–D12) se asumen vigentes. Las que estaban abiertas (`[DECISIÓN HUMANA]` / §10) se resuelven así:

| ID | Decisión | Resolución | Razón |
|----|----------|-----------|-------|
| **ADR-1** | Secuenciación del programa | **Por fases** (Fase 0→4, capability-by-capability) | Cada fase gatea la siguiente; baja sorpresa; coherente con el roadmap del spec. |
| **ADR-2** | Orquestación / malla (D10) | **Static peers primero → migrar a Maia gossip cuando madure**; K8s como 3er backend futuro | Static peers es nativo, robusto y sin el auth-gap de Maia. Ambos son config del mismo runtime: migrar no rehace el OS. |
| **ADR-3** | Línea base de kernel | **Debian trixie / kernel 6.12+ LTS** | Habilita Landlock (≥5.13), eBPF/io_uring/XDP modernos. ⚠️ **Corrección (2026-06-16):** el kernel 6.12 de trixie **NO** trae `CONFIG_SCHED_CLASS_EXT` (cloud/generic/rt; confirmado por `.config`), así que `sched_ext` (§12.2a) **no** es posible en este baseline pese a ser ≥6.12 — Debian lo activó recién en 7.0 (disponible en `trixie-backports`). 12.2a queda implementado pero con gate diferido; el resto de §12 (12.1/12.4/12.6/12.3/12.7) no se ve afectado. Ver `phase12.2a-schedext-design.md` §0.1. |
| **ADR-4** | Caps `required: true` (fail-closed) por default | **12.1 (sandbox de tools) + 12.4 (egress)** | El runtime aún no aísla tenants; el OS debe garantizar aislamiento y gobierno de egress o no arrancar el agente. |
| **ADR-5** | Distro base | **Debian trixie** (vs Fedora bootc) | El runtime distribuye `.deb`/nfpm; glibc; estabilidad. Consistente con ADR-3. |
| **ADR-6** | ADK en la imagen | **NO se hornea** | Un nodo de runtime ejecuta agentes ya definidos; el ADK es para desarrollarlos. Ahorra footprint. |
| **ADR-7** | Secure Boot | **Claves propias, diferido a Fase 3** | dm-verity (Fase 2) cubre integridad de root antes; Secure Boot agrega complejidad de provisioning por cloud, mejor cuando la seguridad es el foco. |
| **ADR-8** | Runtime de sandbox (§6.7/§12.1) | **seccomp+Landlock+namespaces en MVP → microVM (Firecracker/Kata) como fast-follow** | `required:true` (ADR-4) = "no degradar silenciosamente", no "exige microVM". El modo `sandbox` satisface fail-closed en MVP; `microvm` escala después. |
| **ADR-9** | Esquema ORAS / Docker Hub (§6.10) | `MAJOR.MINOR.PATCH` + `latest` + sufijos de variante; media types `application/vnd.astromesh.disk.raw`, `application/vnd.astromesh.sysext.<n>` | Fijar antes del primer push: cambiarlo después es costoso. El artefacto es un **disco vía `oras pull`**, NUNCA `docker run`/`pull`. |
| **ADR-10** | Perfil de equipo (§13.3) | Reconocer **systems/kernel engineer (Rust+eBPF)** como dependencia de talento crítica | Sin ese perfil, §12 colapsa a "una distro con tunables" y el diferencial no existe. |

> Las ADRs 5–10 se adoptaron con el default recomendado del spec y quedan abiertas a objeción en el gate de revisión de este doc.

---

## 3. Decomposición en sub-proyectos

Siete piezas independientes. Cada una tendrá su propio ciclo brainstorm→spec→plan→implementación.

| # | Sub-proyecto | Plano / stack | Secciones del spec |
|---|--------------|---------------|--------------------|
| **A** | **OS Build** — base mínima mkosi + target boot-to-agent + gate de tamaño | build: **mkosi + Bash/Python** | §6.1, §6.1.1, §6.2, §7 |
| **B** | **Inmutabilidad + Updates** — dm-verity, sysext, A/B `sysupdate` | **mkosi + systemd** | §6.3, §6.9 |
| **C** | **Control plane** — `astromeshctl node` (extendido), machine-config, malla (static peers→Maia) | sistema: **Rust** | §6.4, §6.4.1 |
| **D** | **Seguridad** — TPM/secretos sellados, atestación remota, no-shell + break-glass, SELinux | **Rust + systemd** | §6.5, §6.6, §6.8(watchdog) |
| **E** | **Sandboxing** — aislamiento de tool-execution (seccomp+Landlock → microVM) | sistema: **Rust** | §6.7, §12.1 |
| **F** | **Diferencial de kernel §12** (transversal) — egress, telemetría causal, scheduler, mem, snapshot | kernel: **C-eBPF** + control: **Rust** | §12 completo |
| **G** | **Distribución / cloud** — ORAS a Docker Hub, conversión AMI/VHD/GCP image | distribución: **Bash/CLI** | §6.10, `cloud/` |

**Observabilidad (§6.8)** es transversal: arranca como config OTel en A/D y se completa con la atribución causal eBPF de F (12.6) en Fase 4.

### Grafo de dependencias

```
A (OS Build)
├──> B (Inmutabilidad+Updates)
│     ├──> D (Seguridad)
│     ├──> E (Sandboxing) ──> F (§12 kernel)   [F también depende del baseline de kernel ADR-3]
│     └──> F (§12 kernel)
├──> C (Control plane)
└──> G (Distribución/cloud)
```

Regla de aislamiento: cada sub-proyecto expone una interfaz declarativa (machine-config / Agent YAML / artefacto OCI / API de nodo) y se puede entender y testear sin leer las internals de los otros.

---

## 4. Roadmap secuenciado (gate por fase)

No se avanza de fase sin que la anterior bootee y pase su check.

| Fase | Entrega (sub-proyectos) | Exit check (gate) |
|------|-------------------------|-------------------|
| **0 — Validación del unit** | Subset de **A**: Astromesh-core como systemd service sobre imagen mkosi/Debian estándar, boot a qcow2 en QEMU/KVM | `200` en `/v1/health` **y** una query de agente respondida vía API contra un provider frontier. `astromeshctl doctor` en verde. |
| **1 — Mínima + boot-to-agent** | **A** completo (target custom, recorte agresivo, gate §7) + **G**-mínimo (push del artefacto OCI vía ORAS) | imagen core **≤ 500 MB** **y** bootea como imagen de cloud. El build **falla** si excede el techo. |
| **2 — Inmutabilidad + updates** | **B**: dm-verity sobre root, root read-only, A/B con `systemd-sysupdate` + rollback automático | update + rollback probados (boot nuevo que falla health → rollback). |
| **3 — Seguridad** | **D** (TPM/secretos, atestación, no-shell+break-glass, SELinux enforcing) + **E**-MVP + **F** fail-closed (**12.1**, **12.4**) + Secure Boot (ADR-7) | secreto accesible **solo** con boot íntegro; agente **no arranca** sin sandbox (12.1) ni egress (12.4) garantizados. |
| **4 — Agent-native + flota** | **C** (static peers, machine-config declarativo, provisioning AKS/EKS/GKE) + **F**:12.6 (telemetría causal) + OTel exportando + sysext-gpu opcional | nodo **joinea la malla solo con machine-config** (sin SSH). |
| **post-4** | **F** restante: 12.2 (`sched_ext` scheduler + GPU broker), 12.3 (mem/OOM con semántica de agente), 12.7 (snapshot/restore CRIU) | ganancia incremental, cada uno con su check. |

### F (el diferencial) es transversal a las fases

- **12.1** (sandbox kernel) y **12.4** (egress eBPF/XDP) → **Fase 3** (seguridad, fail-closed por ADR-4).
- **12.6** (atribución causal eBPF) → **Fase 4** (cierra el círculo de observabilidad de §6.8).
- **12.2 / 12.3 / 12.7** → **post-Fase 4** (incremental, no exclusivo del nivel OS).

**Núcleo defendible (MVP del diferencial):** 12.1 (aislamiento real) + 12.4 (gobierno de egress) + 12.6 (atribución causal de costo). Encuadre de validación: el OS se justifica por **confianza, atribución y densidad**, no por "va más rápido".

---

## 5. Riesgos y mitigaciones

| ID | Riesgo | Mitigación |
|----|--------|-----------|
| **R1** | **Build Linux-only sobre host Windows.** mkosi/QEMU/eBPF/CRIU no corren nativo en Windows. | Build en **CI Linux (GitHub Actions)**; WSL2 para iteración local. microVM/KVM anidado (Fase 3+) puede exigir runner Linux con **nested-virt** (cloud), no WSL2. |
| **R2** | **Madurez de Maia**: endpoints `/v1/mesh/*` sin auth; Bully election → sistema AP con riesgo de **split-brain**; runtime aún sin multi-tenant. | **Static peers primero** (ADR-2). Cerrar gap de auth (**mTLS + atestación TPM antes del join** + secreto de membership sellado a TPM) **antes** de exponer cualquier endpoint de malla. El aislamiento entre agentes lo garantiza el OS (E/F), no el runtime. |
| **R3** | **Talento Rust+eBPF** es la dependencia más crítica (§13.3). | Reconocer temprano (ADR-10). Sin ese perfil, §12 (F) no se construye y el proyecto degrada a "distro con tunables". Las fases 0–2 no lo requieren; F sí. |
| **R4** | **Techo 500 MB** (§7). El término dominante es el **closure de Python** del runtime, no la distro. | Medir desde Fase 1 con un **gate que falla el build**. Purgar tests/docs/`__pycache__`/deps opcionales; evaluar `pip install --no-deps` selectivo. Optimizar Python antes que pulir la base. |
| **R5** | **Versión del runtime inconsistente** (tag local `adk-v0.1.7` vs spec `v0.15.x`). La imagen inmutable exige reproducibilidad. | **Pinear versión exacta** resolviendo contra `releases/latest` del repo `monaccode/astromesh` al construir. Preferir el `.deb`/nfpm de GitHub Releases; fallback `uv sync` + `maturin develop --release`. Verificar con `astromeshctl doctor` como gate de Fase 0. |
| **R6** | **Provisioning de Secure Boot por cloud** (claves propias MOK/db) es específico de cada nube. | Diferir a **Fase 3** (ADR-7). dm-verity (Fase 2) cubre integridad de root mientras tanto. |
| **R7** | **`runtime.yaml` bajo FS inmutable.** Se genera en boot, no puede vivir en `/usr` verity. | Generarlo en ruta escribible (`/var` o `/etc` por tmpfs/overlay). Perfiles read-only horneados en `/etc/astromesh/profiles/`. Contemplar en el layout de FS (§4 del spec) desde el sub-proyecto A. |

---

## 6. Entregable de esta sesión y siguiente paso

**Producido en esta sesión:**
- Repo nuevo: `/d/monaccode/astromesh-os` (hermano de `astromesh`), `git init` en branch `main`.
- Este documento de diseño/decomposición. **Sin código de build.**

**Siguiente ciclo (en una sesión aparte):**
- Brainstorm → spec → plan de **Fase 0** específicamente (subset de sub-proyecto A): Astromesh-core como systemd service, boot QEMU, una query de agente. Es la raíz de la que todo depende.

**Anti-objetivos vigentes (del spec §11), recordatorio para todas las fases:**
- ❌ No escribir kernel/init desde cero; systemd se queda.
- ❌ No musl/Alpine.
- ❌ No hornear CUDA ni inteligencia de agentes en la base.
- ❌ No shell/SSH interactivo por default.
- ❌ No forkear `talosctl`/Bottlerocket — extender `astromeshctl`.
- ❌ No acoplar la base a ningún sysext.
- ❌ No superar 500 MB en la imagen core (el build falla).
- ❌ No tratar el artefacto OCI como contenedor (`oras pull`, no `docker run`).
- ❌ No exponer las capacidades de kernel (§12) como tunables sueltos: siempre por las dos superficies declarativas (Agent YAML ∩ machine-config).
- ❌ No degradar silenciosamente una capability `required: true`.
