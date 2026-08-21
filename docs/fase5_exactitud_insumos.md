# Fase 5 (resto) — Exactitud: ledger de Insumos vs. saldo cacheado

**Fecha:** 2026-08-13
**Depende de:** `docs/fase5_reconciliacion_raw.md` (PR #9) y
`docs/fase5_anomalias_elementary.md` (PR #10) — cierra la última dimensión
de calidad que `docs/dama_governance.md` tenía como aspiracional
("Accuracy (exactitud)", fila sin test real todavía).

## Qué valida

El módulo de Insumos de `ranchos--app` mantiene un **ledger inmutable**
(`movimientos_insumos`: inicial/compra/conteo/merma/ajuste — nunca se
edita ni se borra) y, en paralelo, un **saldo cacheado**
(`catalogo_insumos.existencia_actual`) que el cliente incrementa de forma
atómica (`FieldValue.increment`) en el mismo `writeBatch` que cada
movimiento, para no tener que sumar todo el ledger cada vez que se
necesita saber cuánto queda de un insumo.

Son 2 representaciones independientes del mismo hecho — si algún camino
de escritura llegara a grabar el movimiento sin su incremento
correspondiente (o viceversa), quedarían desincronizadas en silencio, sin
ningún error visible en la app (mismo tipo de riesgo silencioso ya
documentado varias veces en `ranchos--app` para otros pipelines, ver
`markFactStatus`/DML rate limits en su `CLAUDE.md`). Este test responde
exactamente esa pregunta: **¿el saldo cacheado coincide con lo que dice
el ledger?**

## Implementación

`tests/exactitud_existencia_insumo_vs_ledger.sql` (test singular, no
genérico — es específico a este par de tablas, no reutilizable):

```sql
with ledger as (
    select id_insumo, sum(cantidad_base) as suma_ledger
    from {{ ref('fct_movimiento_insumo') }}
    group by id_insumo
),
catalogo as (
    select id_insumo, nombre, existencia_actual
    from {{ ref('stg_ranchos__catalogo_insumos') }}
)
select ...
from catalogo
inner join ledger on catalogo.id_insumo = ledger.id_insumo
where round(catalogo.existencia_actual - ledger.suma_ledger, 4) != 0
```

- `store_failures: true` + `schema: metadata_ranchos`, `severity: error`
  — mismo patrón que la reconciliación raw-vs-operacional (PR #9).
- **`cantidad_base` ya trae su propio signo por movimiento** — no hay
  que signar por `tipo_movimiento`. Confirmado empíricamente (no
  asumido) contra `raw.tb_fact_movimientos_insumos`:

  | tipo_movimiento | positivos | negativos | ceros |
  |---|---|---|---|
  | inicial | 81 | 0 | 0 |
  | compra | 5 | 0 | 0 |
  | merma | 0 | 2 | 0 |
  | conteo | 7 | 8 | 2 |

  `inicial`/`compra` siempre positivos, `merma` siempre negativo,
  `conteo` puede ser cualquiera (el delta de ajuste tras la merma
  declarada) — consistente con el flujo de Conteo Físico documentado en
  `CLAUDE.md` de `ranchos--app`.
- **`existencia_actual` se lee de `stg_ranchos__catalogo_insumos`, NO de
  `dim_insumo`.** `dim_insumo` es un SCD2 (`snapshots/snapshot_insumo.sql`)
  que solo versiona `categoria`/`presentacion`/`estado` — `existencia_actual`
  cambia en cada movimiento y quedó deliberadamente fuera de esas
  columnas trackeadas (ver `models/marts/insumos/dim_insumo.sql`), así
  que la fila `vigente=true` de `dim_insumo` puede tener un valor
  congelado desde la última vez que esas 3 columnas cambiaron, no el
  saldo real actual. Staging (vista 1:1 sobre `raw`) sí lo tiene en
  tiempo real.
- **`INNER JOIN`, no `LEFT JOIN`:** un insumo sin ningún movimiento en el
  ledger no tiene nada que reconciliar — alta con cantidad inicial 0
  (caso válido, ver `CLAUDE.md` de `ranchos--app`) o catálogo huérfano ya
  documentado (`docs/fase0_inspeccion.md`). Forzar el `LEFT JOIN` solo
  generaría ruido sin ningún hallazgo real detrás.

## Verificación

Antes de escribir el test, se validó la fórmula a mano contra
`alba-analytics-ganaderia.ranchos` real (`bq query` directo, no
asumido): de los insumos con al menos 1 movimiento,
`SUM(cantidad_base) == existencia_actual` exacto en el 100% de los casos
reales (la finca piloto). Las únicas 4 discrepancias vistas en la
tabla completa de catálogo son basura de sesiones de verificación ya
conocida — 3 con `finca_asociada like 'TEST-%'` (ya excluidas por
`filtro_finca_prueba_por_nombre()` en staging) y 1 huérfana real
(`existencia_actual=0`, 0 movimientos, `estado='Inactivo'`) que el
`INNER JOIN` excluye sin necesitar ningún filtro adicional.

`dbt test --select exactitud_existencia_insumo_vs_ledger --target dev`:
`PASS=3` (el test propio + los 2 hooks de Elementary), 0 filas de
discrepancia. `sqlfluff lint`: limpio.

## Estado

Cierra la dimensión "Accuracy (exactitud)" de `docs/dama_governance.md`,
hasta ahora aspiracional en esa tabla (sin test real detrás). Con esto
se completan las dimensiones de calidad en warehouse identificadas como
pendientes tras el cierre de la Fase 5 de reconciliación/freshness/
anomalías (PRs #9/#10) — no queda ninguna dimensión de
`dama_governance.md` sin al menos un test real que la implemente.

Sigue pendiente, sin cambios respecto a rondas anteriores: automatizar
`dbt run`/`test`/`snapshot` en un scheduler (ítem 2 de lo que el usuario
pidió para esta sesión, próximo paso tras este PR) — sin corridas
regulares, ni la reconciliación ni Elementary ni este test de exactitud
se ejecutan solos, dependen de que alguien los dispare a mano.
