# Punto de Control 2 — `movimientos_insumos` de punta a punta

**Fecha:** 2026-08-13
**Alcance:** un solo hecho completo (raw → staging → integración →
dimensiones asociadas → hecho → 1 vista de reportería), tal como pide la
Fase 4 del documento de especificación, antes de replicar el patrón al
resto de los dominios. **No se tocó ningún otro dominio en esta fase.**

---

## Grano de cada modelo (declarado en una frase, antes de escribir el SQL)

- **`fct_movimiento_insumo`**: un movimiento de inventario de un insumo
  (inicial/compra/conteo/merma/ajuste).
- **`dim_insumo`**: una versión histórica de un insumo (SCD tipo 2 sobre
  `categoria`/`presentacion`/`estado` — un insumo tiene N filas si cambió
  N-1 veces).
- **`dim_finca`**: una finca (sin historización).
- **`dim_fecha`**: un día calendario (generada, 2020-01-01 a 2035-12-31).
- **`rpt_movimientos_insumo_recientes`**: un movimiento (hereda el grano
  de `fct_movimiento_insumo`, con nombres legibles en vez de FKs).

## Capas implementadas

| Capa | Archivo(s) |
|---|---|
| L1 staging | `stg_ranchos__movimientos_insumos`, `stg_ranchos__catalogo_insumos`, `stg_ranchos__fincas` |
| L2 integración (historización) | `snapshots/snapshot_insumo.sql` — SCD2, estrategia `check` |
| L2 integración (conformado) | `int_movimientos_insumos_con_insumo_historico` — ephemeral, resuelve la versión de insumo vigente al momento del movimiento |
| L3 marts | `dim_finca`, `dim_fecha` (`marts/comun/`, conformadas) + `dim_insumo`, `fct_movimiento_insumo` (`marts/insumos/`) |
| L4 reporting | `rpt_movimientos_insumo_recientes` (`reporting/insumos/`) |

## 2 problemas reales encontrados y corregidos (no eran bugs de sintaxis — eran de datos/diseño)

1. **Datos de prueba contaminando producción.** El test de integridad
   referencial (`relationships` de `finca_asociada` → `dim_finca`) falló
   con 20 filas huérfanas reales: fincas `TEST-DEBUG-INSUMOS-RULES`,
   `TEST-DEBUG-CLIENT-SDK`, `TEST-VERIFICACION-INSUMOS-FASE1` — residuos
   de sesiones de verificación de `ranchos--app` que no se limpiaron del
   todo en producción (coincide con 2 filas huérfanas ya documentadas en
   `CLAUDE.md` de ese repo como "fuera de alcance"; acá aparecieron más).
   **No se tocó `ranchos-7c313`** (requeriría un DELETE de producción con
   confirmación explícita, fuera de alcance de este checkpoint) — se
   excluyen en `staging/` con un filtro documentado
   (`finca_asociada not like 'TEST-%'`), reportado acá en vez de
   resuelto en silencio.
2. **El join punto-en-el-tiempo no encontraba match para ningún
   movimiento real.** Como esta es la primera vez que corre
   `dbt snapshot` en este proyecto, TODAS las versiones de `snapshot_insumo`
   nacieron con `dbt_valid_from` = el momento de esa primera corrida — y
   los 89 movimientos reales son anteriores a ese momento. Un join
   estricto `>= dbt_valid_from` no matcheaba ninguno (los 78 insumos
   salían con `insumo_nombre`/`categoria` vacíos en la vista de
   reportería, confirmado antes de dar el checkpoint por bueno — no se
   asumió que "sin error" significara "correcto"). Corregido con un
   fallback documentado en `int_movimientos_insumos_con_insumo_historico.sql`:
   si no hay una versión vigente para la fecha del movimiento, se usa la
   versión más antigua conocida del insumo (la mejor aproximación
   disponible). A medida que se acumule historia real de ediciones de
   insumos, la coincidencia exacta empezará a aplicar para movimientos
   futuros sin cambiar el modelo.

## Verificación

- `dbt build` (run + test + snapshot) completo: **69/69 tests, 0
  errores** — 1 snapshot, 4 modelos de tabla, 5 modelos de vista.
- `sqlfluff lint` sobre los 10 archivos nuevos: limpio (11 violaciones de
  formato auto-corregidas con `sqlfluff fix`, sin cambios de lógica).
- Datos reales verificados en la vista de reportería (no solo "los tests
  pasan"): movimientos de la finca piloto con `insumo_nombre`/
  `categoria` resueltos correctamente (ej. "Harina de Soya" / "Insumo de
  Alimento", "Yodo" / "Insumos de Ordeño").
- `dim_fecha`: `estacion` calculada con el patrón Seca (dic-abr) /
  Lluviosa (may-nov) confirmado con el usuario. `ciclo_productivo` queda
  `NULL` — sin concepto de negocio confirmado, documentado como
  pendiente, no bloqueó el checkpoint.

## Estado

Punto de Control 2 cumplido. **No se replicó el patrón a otros hechos
todavía** — queda pendiente de tu revisión antes de aplicar el mismo
patrón (staging → snapshot/intermediate → dims → fact → reporting) al
resto de los dominios (Finanzas, Leche, Hato, Veterinaria).
