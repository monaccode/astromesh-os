# Local dev loop (WSL2 + KVM) — diseño

> **Estado:** Aprobado en brainstorming 2026-06-08.
> **Motivación:** El loop de iteración del OS hoy depende exclusivamente de GitHub
> Actions (cola + build-deb + build-images ×2 + gate de boot, ~10-13 min) y los boots
> corren bajo **TCG sin KVM** → lentos y *flaky*. Un cambio de una línea en
> `mkosi.repart` cuesta un round-trip completo de CI solo para descubrir si el build
> o el boot rompen. Necesitamos reproducir el gate **localmente, en minutos y sin
> flakiness**, manteniendo CI como gate autoritativo.

---

## 1. Objetivo y criterios de éxito

Un desarrollador en el host Windows puede, con **un comando**, reproducir localmente
el mismo gate que corre en `phase2b-update.yml`:

1. Construir la imagen v1 (y v2 para A/B) con el **mismo `mkosi.conf`** que CI.
2. Bootearla en QEMU **con KVM** (rápido, sin la race de enumeración de device de TCG).
3. Asertar los mismos marcadores que CI (`IMMUTABILITY OK`, `/v1/health` 200,
   `ASTROMESH_BUILD=<v>`, gate A/B v1→v2).

**Definición de hecho:**
- `tests/local/dev-loop.sh update` corre de punta a punta en WSL2 y reproduce el
  resultado del gate de CI (verde local ≈ verde CI) en una fracción del tiempo.
- El boot usa `/dev/kvm` (verificado) — no TCG.
- La fuente de verdad del repo sigue en `D:\monaccode\astromesh-os`; no se altera el
  flujo de edición actual.

**Fuera de alcance (YAGNI):** correr esto en macOS/Linux nativo; integrar el loop
local con runners self-hosted; eliminar CI (sigue siendo el gate autoritativo).

---

## 2. Restricción de base que define el diseño

mkosi construye un **rootfs Linux real**: necesita `chown`, nodos de device
(`mknod`), xattrs y loop devices. El filesystem `/mnt/d` de WSL2 (drvfs) **no**
soporta esa semántica, así que el build **no puede** ocurrir sobre `D:\`. De ahí dos
decisiones estructurales:

- El build corre en el **fs ext4 nativo de WSL** (`~/astromesh-build`).
- La distro WSL2 debe ser **una distro real** (Debian) — la `docker-desktop` que ya
  existe no sirve: los contenedores en Windows no exponen `/dev/kvm`.

---

## 3. Arquitectura

```
Windows (D:\monaccode\astromesh-os)          WSL2 Debian (fs ext4 nativo)
  - edición (Claude / editor)                  ~/astromesh-build/  ← rsync destino
  - git, gh (autenticado)             rsync     - mkosi build (sudo/root)
  - dist/  (cache del .deb) ───────────────────▶ - qemu-system-x86_64 -enable-kvm
                                                 - tests/boot/*.sh (reusados de CI)
```

### 3.1 Setup one-time (documentado en README)
- `wsl --install -d Debian`.
- `/etc/wsl.conf` → `[boot]\nsystemd=true` (mkosi/`systemd-nspawn`/repart esperan
  systemd disponible); `wsl --shutdown` para aplicar.
- Instalar el mismo toolset que CI:
  `mkosi systemd-ukify systemd-boot mtools dosfstools qemu-system-x86 ovmf qemu-utils
  rsync curl python3` (+ lo que CI instale en `build-images` / `update-gate`).
- **Verificar KVM:** existe `/dev/kvm` y es usable. Si no:
  `%UserProfile%\.wslconfig` → `[wsl2]\nnestedVirtualization=true` + `wsl --shutdown`.
  Sin KVM el ejercicio no tiene sentido → el harness **falla con mensaje claro** si no
  encuentra `/dev/kvm`.
- El build corre como **root** (`sudo`), igual que el contenedor privilegiado de CI.

### 3.2 Fuente de verdad y sync
- Repo canónico: `D:\monaccode\astromesh-os` (visible en WSL como
  `/mnt/d/monaccode/astromesh-os`).
- El harness hace `rsync -a --delete` de la fuente → `~/astromesh-build/`, excluyendo
  `.git/`, `mkosi.output/`, `_runtime/`, `mkosi.builddir/` y artefactos de boot
  (`*.qcow2`, `ovmf_vars.fd`, `qemu-console.log`).
- Todo build/boot ocurre en `~/astromesh-build/`.

### 3.3 El runtime `.deb`
Para iterar el **OS** el `.deb` casi nunca cambia. Estrategia:
- Por defecto, **descargar el último artefacto `astromesh-deb` de un run de CI exitoso**
  con `gh run download` (corrido del **lado Windows**, donde `gh` ya está autenticado),
  cachearlo en `dist/`. Sólo se re-descarga si `dist/` está vacío o si `runtime.pin`
  cambió respecto al `.deb` cacheado (marcador `dist/.deb-ref`).
- El harness en WSL **asume** que `dist/*.deb` existe (lo trae el sync); si falta, falla
  con instrucción de correr el fetch.
- *Alternativa documentada (no default):* construir el `.deb` en WSL clonando
  `monaccode/astromesh` al ref de `runtime.pin` + `nfpm`.

### 3.4 El harness `tests/local/dev-loop.sh`
Bash, corre **dentro de WSL2**. Porta los pasos de `phase2b-update.yml`. Targets:

| Target | Acción |
|--------|--------|
| `build` | sync → `mkosi --image-version=1 build` |
| `boot`  | `build` + boot v1 con KVM + `tests/boot/run-and-assert.sh` (IMMUTABILITY OK + health + marker) |
| `update` (default) | v1 + `mkosi --image-version=2 --force build` + stage/serve artefactos v2 + `tests/boot/update-and-assert.sh` (gate A/B v1→v2) |
| `clean` | borra `~/astromesh-build/mkosi.output` y artefactos de boot |

- **Reusa los mismos `tests/boot/*.sh` que CI** → paridad. La única diferencia
  intencional es el acelerador (KVM local vs TCG en CI); el build mkosi es idéntico, así
  que la reproducibilidad de verity, el layout A/B, el roothash en el UKI, etc. se
  validan igual que en CI.
- El serve de artefactos v2 (HTTP `:8088` + `LATEST`) replica el paso del workflow.
- Un launcher de conveniencia del lado Windows (opcional): invocar
  `wsl -d Debian -- bash /mnt/d/monaccode/astromesh-os/tests/local/dev-loop.sh <target>`.

---

## 4. Paridad con CI y divergencias conocidas

- **Idéntico:** `mkosi.conf`, `mkosi.repart/`, `mkosi.postinst.chroot`, los scripts
  `tests/boot/*.sh`, el set de paquetes de build.
- **Divergente a propósito:** KVM local vs TCG en CI (local más rápido y estable).
  Por eso el harness comparte el `ACCEL`/`-enable-kvm` ya existente en
  `update-and-assert.sh` y simplemente encontrará `/dev/kvm`.
- **Riesgo:** un bug que sólo aparezca bajo TCG (timing) no se vería localmente. Mitiga:
  CI sigue siendo el gate final antes de merge.

---

## 5. Componentes a crear / modificar

| Archivo | Acción |
|---------|--------|
| `tests/local/dev-loop.sh` | **Crear** — harness con targets build/boot/update/clean. |
| `tests/local/fetch-deb.ps1` (o sección del README) | **Crear** — fetch+cache del `.deb` desde CI vía `gh` (lado Windows). |
| `README.md` | **Modificar** — sección "Local dev loop (WSL2 + KVM)": setup one-time + uso. |
| `.gitignore` | **Modificar** si hace falta — ignorar artefactos locales nuevos. |
| `tests/boot/*.sh` | Sin cambios (se reusan tal cual). |

---

## 6. Riesgos

| Riesgo | Mitigación |
|--------|------------|
| `/dev/kvm` no disponible en WSL2 (nested-virt off). | Verificación temprana + instrucción `.wslconfig`; el harness aborta con mensaje claro. |
| mkosi en WSL2 necesita systemd/nspawn no presente. | Habilitar `systemd=true` en `wsl.conf`; correr como root. |
| Perf/permdrvfs si alguien corre el build sobre `/mnt/d` por error. | El harness fuerza el workdir nativo `~/astromesh-build` y no construye en `/mnt/d`. |
| Drift entre el `.deb` cacheado y `runtime.pin`. | Marcador `dist/.deb-ref`; re-fetch si difiere. |
