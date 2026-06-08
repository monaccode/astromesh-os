# Fase 2b-rollback — diseño (boot-assessment health-gated)

> **Estado:** Aprobado en brainstorming 2026-06-08.
> **Depende de:** Fase 2b-update (A/B + verity + updater propio), ya verde en `main`
> (gate `v1→v2` pasa: ver `docs/superpowers/2026-06-06-phase2b-update-STATUS.md`).
> **Motivación:** Un update A/B sin rollback es peligroso: si la nueva versión bootea
> pero no llega a *healthy* (astromeshd caído, regresión), el nodo queda inutilizable.
> Necesitamos que un boot nuevo que falla health **vuelva automáticamente** al slot
> anterior bueno.

---

## 1. Objetivo y criterios de éxito

Tras un update A/B, el slot nuevo se prueba; si no alcanza *healthy* en un número
acotado de intentos, el sistema **rollback** automáticamente al slot anterior bueno.

**Definición de hecho (gate):**
- **Update sano** (regresión): v1 → update a v2 sano → v2 alcanza health → v2 queda
  marcado bueno y **estable** (sin rollback). (Lo cubre el gate de 2b-update actual.)
- **Update malo + rollback**: v1 → update a un **v2 unhealthy** → v2 agota sus intentos
  → el sistema **arranca v1** de nuevo → `ASTROMESH_BUILD=1` + `/v1/health` 200.
- El slot bueno (v1) **nunca** entra en loop de reboot por el mecanismo de rollback.

**Fuera de alcance (YAGNI):** firma/Secure Boot del boot-counting (Fase 3); rollback de
`/var` (datos persistentes, compartidos por diseño); más de dos slots.

---

## 2. Mecanismo: boot assessment nativo de systemd-boot

systemd-boot soporta *automatic boot assessment* sobre UKIs Type 2:

- Un UKI en `…/EFI/Linux` con sufijo de intentos `<base>+<tries>.efi`
  (p.ej. `astromesh-os-phase0_2+3.efi` = 3 intentos) es una entrada **en prueba**.
- En cada arranque de esa entrada, systemd-boot la renombra decrementando los intentos
  y contando los hechos: `+3` → `+2-1` → `+1-2` → `+0-3`.
- Con **0 intentos restantes** (`+0-3`), systemd-boot la considera **mala** y la saltea,
  seleccionando la próxima entrada válida (el UKI de v1, que es bueno).
- Un boot **healthy** marca la entrada como **buena**: `systemd-bless-boot` le quita el
  contador (`…_2+2-1.efi` → `…_2.efi`), permanente.
- El UKI de **v1** se instala **sin contador** → baseline bueno, siempre seleccionable
  como destino de rollback.

Esto encaja directo con el modelo UKI A/B de 2b-update (systemd-boot ya elige el UKI de
mayor versión; el contador sólo decide si la entrada en prueba sigue siendo elegible).

---

## 3. "Healthy" y el gate de boot-check

Service nuevo **`astromesh-boot-check.service`** (oneshot, corre al final del boot):

1. **Sólo actúa en un boot de prueba** (contador de intentos activo). Si el boot ya es
   bueno (sin contador), no hace nada — así el slot bueno (v1) **nunca** se rebootea por
   este mecanismo aunque algo transitorio falle. (Chequea el estado vía
   `systemd-bless-boot status` / la presencia del marcador de boot-counting.)
2. Polea `/v1/health` hasta **`HEALTH_TIMEOUT` (default 90s)**.
3. **200 → `systemd-bless-boot good`** → la entrada queda buena, sin rollback.
4. **Timeout (unhealthy) → `systemctl reboot`** → gasta un intento; systemd-boot
   decrementa en el próximo arranque.

El timeout de 90s da margen a un boot lento-pero-sano (sobre todo bajo TCG en CI) para
evitar un rollback falso.

---

## 4. Flujo de rollback (v2 unhealthy)

```
updater instala _2+3.efi (3 intentos) + escribe/relabela slot inactivo → reboot
 ├─ intento 1: systemd-boot _2+3 → _2+2-1, bootea v2 → boot-check: health timeout → reboot
 ├─ intento 2: _2+2-1 → _2+1-2, bootea v2 → unhealthy → reboot
 ├─ intento 3: _2+1-2 → _2+0-3, bootea v2 → unhealthy → reboot
 └─ intento 4: _2+0-3 = 0 restantes → systemd-boot saltea v2, bootea _1.efi (v1)
               → v1 healthy → estable. ROLLBACK COMPLETO.
```

Caso sano: en el intento 1, health 200 → `systemd-bless-boot good` → `_2.efi`
permanente → v2 estable, sin más reboots.

---

## 5. Componentes (crear / modificar)

| Archivo | Acción |
|---|---|
| `phase2b/astromesh-update.sh` | Instalar el UKI v2 con sufijo de intentos: `…_<v>+${TRIES}.efi` (en vez de `…_<v>.efi`). `TRIES` default 3. |
| `phase2b/astromesh-boot-check.sh` | **Crear** — el gate de §3 (sólo en boot de prueba; health → bless good; timeout → reboot). |
| `phase2b/astromesh-boot-check.service` | **Crear** — oneshot que corre el check al final del boot (`After=astromesh-os.target`/multi-user). |
| `mkosi.postinst.chroot` | `systemctl enable systemd-bless-boot.service astromesh-boot-check.service`; honrar el toggle `ASTROMESH_BREAK_HEALTH` (ver §6). |
| `tests/boot/rollback-and-assert.sh` | **Crear** — gate de rollback (§6). |
| `tests/local/dev-loop.sh` | Target `rollback` que construye el v2 malo, sirve, y corre `rollback-and-assert.sh`. |
| `.github/workflows/phase2b-update.yml` | Job/gate adicional de rollback (v2 malo → vuelve a v1). |

Nota: el `astromesh-os.target` actual `Requires=astromeshd.service`; el boot-check
depende de que astromeshd intente arrancar para evaluar health — no lo reemplaza.

---

## 6. Testing — gate de rollback

**Inducir un v2 unhealthy (toggle de build):** `mkosi.postinst.chroot` honra
`ASTROMESH_BREAK_HEALTH=1` → lisia astromeshd en esa build (p.ej. `systemctl mask
astromeshd.service` o un drop-in con `ExecStart` que sale 1), de modo que `/v1/health`
nunca responde. El toggle **no afecta** los builds normales (default off).

**`tests/boot/rollback-and-assert.sh`:**
1. Bootea v1 (qcow2), confirma v1 up (health 200, `IMMUTABILITY OK`).
2. Sirve un **v2 construido con `ASTROMESH_BREAK_HEALTH=1`** sobre HTTP `:8088`.
3. El updater corre, instala `_2+3.efi`, reboot.
4. Asevera la secuencia: v2 arranca y falla health, se consumen los intentos, y el
   sistema **vuelve a v1** — criterio final: `ASTROMESH_BUILD=1` **después** del intento
   de update **y** `/v1/health` 200 (y opcionalmente que el UKI v2 quedó `+0-3` = malo).
5. Timeout global generoso (3 ciclos × ~90s + boots).

**Local:** target `dev-loop.sh rollback` (KVM hace los reboots rápidos). **CI:** gate
adicional en `phase2b-update.yml` (TCG; usa `-accel tcg,thread=multi`).

---

## 7. Defaults y edge cases

- **TRIES=3**, **HEALTH_TIMEOUT=90s** (parametrizables; balance entre tolerar boots
  lentos y no demorar demasiado el rollback).
- **No rebootear el slot bueno:** el boot-check sólo dispara reboot en un boot de prueba
  (contador activo). Si ambos slots fueran malos, v2 hace rollback a v1 por el contador;
  v1 (sin contador) no entra en loop — si v1 estuviera roto el nodo queda en v1 degradado
  (mejor que un reboot-loop infinito; es el baseline asumido bueno).
- **Carrera marcador/health:** igual que en 2b-update, el marcador `ASTROMESH_BUILD` es
  best-effort; el criterio del gate es health + el slot final, no el marcador.
- **`/var` compartido:** sin cambios respecto a 2b-update (seed fijo); el rollback no
  toca `/var`.

---

## 8. Artefactos relacionados
- 2b-update (base): `docs/superpowers/specs/2026-06-06-phase2b-update-v2-design.md`,
  `docs/superpowers/2026-06-06-phase2b-update-STATUS.md`.
- Loop local: `docs/superpowers/specs/2026-06-08-local-dev-loop-design.md`,
  `tests/local/dev-loop.sh`.
