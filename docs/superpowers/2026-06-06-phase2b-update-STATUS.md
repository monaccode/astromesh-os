# Fase 2b-update — estado y follow-up (bankeado 2026-06-06)

> **Estado:** Pausado/bankeado en `feat/phase2b` (NO mergeado). Fase 0/1/2a quedan completas y verdes en `main`.
> **Por qué:** ~18 iteraciones de CI entre dos enfoques; el boot A/B con dm-verity en este stack (mkosi 25.3 / Debian trixie / UKI) tiene comportamiento sutil y en parte flaky. Retorno marginal bajo vs. el resto del programa. Decisión de producto: bankear y retomar con tiempo dedicado.

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
