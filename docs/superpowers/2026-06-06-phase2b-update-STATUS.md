# Fase 2b-update — estado y follow-up (bankeado 2026-06-06)

> **✅ Fase 2b-rollback RESUELTO 2026-06-08 (gate local verde; CI en curso run `27170192681`).**
> El rollback A/B automático funciona end-to-end en el loop local WSL2+KVM
> (`tests/local/dev-loop.sh rollback` → `ROLLBACK GATE PASSED`). Evidencia del boot:
> v1 instala el UKI de prueba `…_2+3.efi`, bootea la v2 deliberadamente unhealthy, y en
> cada uno de los **3 trial boots** `astromesh-boot-check` ve `status=indeterminate` →
> `/v1/health` nunca da 200 → `UNHEALTHY after 90s — rebooting`; systemd-boot decrementa
> el contador `_2+3 → … → _2+0-3.efi` (agotado), cae a v1; marcadores `ASTROMESH_BUILD`
> en orden `2,2,2,1`; v1 final `status=clean` + `/v1/health 200`; y el updater registra
> `v2 already failed boot assessment; not retrying` (sin loop update→fail→rollback→update).
>
> **Mecanismo:** boot-counting nativo de systemd-boot. El updater instala el UKI nuevo con
> sufijo `+tries`; un oneshot `astromesh-boot-check` sólo en trial boot marca el slot bueno
> con health 200 o rebootea para consumir un try; agotados los tries systemd-boot vuelve al
> UKI bueno previo. Se enmascara el `systemd-bless-boot.service` stock para que el blessing
> sea sólo por salud.
>
> **Dos bugs que destrabó el gate (ambos en el harness/inyección de fallo, no en el
> mecanismo):**
> 1. `ASTROMESH_BREAK_HEALTH` enmascaraba `astromeshd`, pero `astromesh-os.target`
>    `Requires=astromeshd` → "Failed to isolate default target" (fallo de boot, no boot
>    unhealthy) y el boot-check nunca corría. Fix: drop-in `Type=exec`/`sleep infinity` →
>    la unit queda *activa* (el target isola y se llega a multi-user) pero nada sirve `:8000`.
> 2. El harness abría con un poll de `/v1/health` 180s; v1 auto-actualiza y rebootea en
>    ~13s → ventana de salud ~1s, se perdía por carrera. Fix: esperar el marcador de consola
>    `installed trial UKI` (determinista).
>
> **Limitación conocida (follow-up):** el rollback por boot-check sólo cubre
> "bootea pero unhealthy". Un slot donde `astromeshd` no arranca tampoco isola el target y
> NO rollbackea por este mecanismo — eso requeriría un watchdog de runtime que rebootee en
> hang. Fuera de alcance de 2b-rollback.
>
> Artefactos: `phase2b/astromesh-boot-check.{sh,service}`, cambios en
> `phase2b/astromesh-update.sh` (UKI `+tries` + guard de versión bad), bloque
> `ASTROMESH_BREAK_HEALTH` en `mkosi.postinst.chroot`, `tests/boot/rollback-and-assert.sh`,
> target `rollback` en `tests/local/dev-loop.sh`, job `rollback-gate` en
> `.github/workflows/phase2b-update.yml`. Rama `feat/phase2b-rollback`.

---

> **✅ Fase 2b-update RESUELTO 2026-06-08.** El gate A/B `v1→v2` pasa end-to-end en CI (run
> `27161183858`: `build-deb`/`build-images`/`update-gate` verdes; `UPDATE GATE PASSED`,
> v2 bootea con verity y `/v1/health` 200). Sigue en `feat/phase2b` (no mergeado).
>
> **Qué destrabó (iterado en el loop local WSL2+KVM — ver `tests/local/dev-loop.sh`):**
> 1. **Verity reproducible:** `mkosi.repart/10-root.conf` con tamaño fijo (no `Minimize`)
>    → el `roothash=` del UKI coincide con las particiones del disco (antes no, y por eso
>    `/dev/mapper/root` no aparecía). Esto explica la "contradicción de verity" de abajo:
>    era un mismatch de roothash, no un problema de UKI vs runtime.
> 2. **Updater A/B** (`phase2b/astromesh-update.sh`): detección de slot activo vía el
>    roothash de `/proc/cmdline`; relabel de los UUID GPT del slot inactivo al nuevo
>    roothash (`sfdisk`, paquete `fdisk`) para que el UKI v2 encuentre su verity.
> 3. **`/var` compartido:** `Seed=` fijo en `mkosi.conf` → el fs-UUID de `/var` es estable
>    entre v1/v2 (si no, el `var.mount` de v2 colgaba → emergency).
>
> Lo de abajo es el estado histórico del bankeo; queda como contexto.

---

## Qué quedó funcionando (en `feat/phase2b`)

- **Layout A/B**: `mkosi.repart/{40-root-b,50-verity-b}.conf` (slots `_empty`) sobre el verity de Fase 2a. La imagen construye con 2 root-data + 2 verity + ESP + /var.
- **Artefactos split versionados**: `SplitArtifacts=uki,partitions` + `mkosi --image-version=N` emite `…_<v>.root-x86-64.raw`, `…-verity.raw`, y el UKI bare `…_<v>.efi`.
- **UKI Type 2**: `UnifiedKernelImages=yes` (+ `systemd-boot-efi`) → UKI en `/EFI/Linux` con roothash + versión embebida.
- **Marcador de versión**: `phase2b/version-marker.*` loguea `ASTROMESH_BUILD=<v>` a consola.
- **Harness multi-boot**: `tests/boot/update-and-assert.sh` (QEMU persistente, poll de marcador, asevera v1→v2). `build-deb`/`build-images` del workflow `phase2b-update.yml` pasan; v1 **bootea** (en la mayoría de las corridas).
- **Updater propio** (`phase2b/astromesh-update.sh`): detección de slot A/B robusta (2 root + 2 verity por índice de repart; activo = el que monta `/` vía `findmnt`/`lsblk -s`), check de versión anti-loop (`LATEST` vs `build-version`), y **streaming `curl | dd`** al slot inactivo + instalar el UKI v2 + reboot. Llegó a detectar correctamente el slot y a streamear (sin problemas de espacio tras el fix).

## El escollo (follow-up)

1. **Boot A/B + verity flaky**: en algunas corridas el primer boot de v1 falla en el **initrd** con timeout esperando un device por PARTUUID y `systemd-veritysetup@root` "dependency failed" → `/sysroot` no monta. La misma imagen bootea bien en otras corridas. Probable causa: timeout de enumeración de device (~90s) bajo TCG (sin KVM) o una race en el setup verity.
2. **Comportamiento de verity confuso bajo `UnifiedKernelImages=yes`**: en el sistema booteado el debug mostró **sin dm device** (`/dev/mapper` sólo `control`, root montado directo de la partición), pero el initrd SÍ intenta `systemd-veritysetup@root`/`/dev/mapper/root`. Esa contradicción (verity activo en initrd vs. ausente en runtime) hay que entenderla — sugiere que `UnifiedKernelImages` cambió el modelo de montaje del root respecto a Fase 2a (donde verity SÍ estaba activo como `/dev/mapper/root`).

## Próximos pasos sugeridos (cuando se retome)

1. **Estabilizar el boot del harness**: forzar KVM en el runner (o subir timeouts del initrd / agregar retry de boot) para descartar la flakiness antes de seguir con la lógica de update.
2. **Aclarar verity bajo UKI**: verificar con `phase0-ci` (que corre el self-check `IMMUTABILITY OK`) si la inmutabilidad verity sigue activa con `UnifiedKernelImages=yes`. Si `UnifiedKernelImages` rompió verity en runtime, decidir: (a) volver a Type 1 BLS (verity andaba) y actualizar kernel+initrd+entry, o (b) arreglar el setup verity con UKI.
3. **Updater**: ya está cerca — con un boot estable, validar que `dd` al slot inactivo + el UKI v2 hagan que systemd-boot elija v2 (`ASTROMESH_BUILD=2`).
4. **2b-rollback** queda después (boot-assessment / boot-counting), más directo sobre el updater propio (marcar el slot bueno; si v2 no llega a healthy, rebootear el slot anterior).

## Artefactos en la rama
- Specs: `docs/superpowers/specs/2026-06-05-phase2b-update-design.md` (sysupdate, descartado), `2026-06-06-phase2b-update-v2-design.md` (updater propio).
- Plan: `docs/superpowers/plans/2026-06-06-phase2b-update-v2.md`.
- Código: `phase2b/astromesh-update.{sh,service}`, `phase2b/version-marker.*`, `mkosi.repart/{40-root-b,50-verity-b}.conf`, `tests/boot/update-and-assert.sh`, `.github/workflows/phase2b-update.yml`, y los cambios A/B/UKI en `mkosi.conf`.
