# Fase 5 (resto) — Detección automática de anomalías con Elementary

**Fecha:** 2026-08-13
**Depende de:** `docs/fase5_reconciliacion_raw.md` (reconciliación de conteo +
source freshness, PR #9) — esta ronda completa el tercer pilar que el
documento de especificación sugiere: *"detección automática de anomalías
sobre volumen de filas, frescura y distribución de columnas... cubre el
caso que ninguna regla escrita a mano anticipa: la colección que dejó de
sincronizar sin producir ningún error."*

## Decisión: Elementary, no algo casero

Confirmado con el usuario (`AskUserQuestion`, 3 opciones): paquete dbt
`elementary-data/elementary` (versión 0.25.1, `>=0.25.0,<0.26.0` en
`packages.yml`) en vez de construir un mecanismo propio sobre
`dbt_expectations` (ya instalado). Es la herramienta estándar del
ecosistema dbt hecha específicamente para esto — detecta anomalías
comparando contra el patrón histórico real acumulado en corridas
sucesivas, no contra umbrales fijos adivinados (que es justo la limitación
que ya tuvo `dbt source freshness` en la ronda anterior, con umbrales que
hubo que ajustar a mano tras probarlos).

## Qué se implementó

- **`packages.yml`**: `elementary-data/elementary` — trae como
  dependencia transitiva `godatadriven/dbt_date`.
- **`dbt_project.yml`**: `models: elementary: +schema: metadata_ranchos`
  — Elementary escribe en el mismo dataset reservado desde la Fase 2 para
  metadata de calidad (`docs/fase2_arquitectura.md`), junto a los
  `store_failures` de la reconciliación, en vez de un dataset
  `elementary` separado.
- **Bootstrap**: `dbt run --select elementary` crea 30 modelos propios
  del paquete (`dbt_models`, `dbt_run_results`, `dbt_tests`, `dbt_sources`,
  `elementary_test_results`, vistas `alerts_*`, etc.) en
  `dev_metadata_ranchos`.
- **Hallazgo — no hace falta configurar hooks a mano:** el paquete
  registra sus propios hooks `on-run-start`/`on-run-end` automáticamente
  (confirmado en la corrida real: `1 of 1 START hook:
  elementary.on-run-start.0` sin ninguna entrada explícita en
  `dbt_project.yml` de este repo) — a diferencia de lo que sugería la
  documentación genérica encontrada al investigar el paquete.
- **3 tests aplicados a las 26 tablas de `sources.yml`** (78 tests en
  total, mismo lugar que la reconciliación y el freshness — un solo
  archivo con todos los controles de calidad de `raw`):
  - `elementary.volume_anomalies` — conteo de filas por bucket de tiempo.
  - `elementary.freshness_anomalies` — más sofisticado que el
    `dbt source freshness` nativo (compara contra el patrón histórico,
    no un umbral fijo).
  - `elementary.all_columns_anomalies` — nulls/mín/máx/distintos por
    columna, automático sobre todas las columnas de cada tabla, sin
    tener que listarlas a mano.
  - `timestamp_column` en `volume_anomalies`/`freshness_anomalies` usa
    la columna real SIN el `cast(... as timestamp)` que sí hace falta
    para el `loaded_at_field` nativo de dbt (ver
    `docs/fase5_reconciliacion_raw.md`) — Elementary maneja columnas
    `DATE` sin problema, confirmado en la prueba piloto contra
    `tb_dim_fincas` antes de aplicarlo a las 26.

## Verificación

- **Prueba piloto (1 tabla, `tb_dim_fincas`) antes de escalar:** los 3
  tests corrieron limpio, con el mensaje esperado *"Not enough data to
  calculate anomaly scores"* — comportamiento correcto para una
  adopción día uno, sin histórico acumulado todavía.
- **Rollout completo (26 tablas, 78 tests):** todos PASS, ~12 minutos de
  corrida real (`dbt test --select tag:elementary`).
- **`dbt build` del proyecto completo** (sin los tests de Elementary,
  verificados aparte): 377/380 — **3 fallos, investigados y confirmados
  como falso positivo transitorio esperado**, no un bug: los tests de
  reconciliación de `tb_dim_catalogo_insumos`/`tb_fact_logs_actividad`/
  `tb_fact_movimientos_insumos` fallaron porque `raw` tenía 2-5 filas
  MENOS que la fuente operacional real en el momento exacto de la
  corrida (`raw`: 84/659/105 vs. operacional: 86/664/107) — nunca al
  revés, consistente con escrituras nuevas en producción entre la
  última sincronización EL (3x/día) y el momento de la verificación. Se
  resuelve solo en la próxima corrida del pipeline EL — exactamente el
  escenario que el propio test documenta como esperado (ver
  `tests/generic/test_reconciliacion_conteo_raw_vs_operacional.sql`).
- `sqlfluff lint`: no aplica (solo cambios de YAML + un paquete de
  terceros).

## Limitación real, no oculta: sin historial todavía

Elementary necesita corridas repetidas de `dbt test`/`dbt build` para
acumular el patrón histórico contra el que compara — hoy (día de
adopción) **no puede detectar ninguna anomalía real todavía**, solo
confirma que la infraestructura funciona. El valor real de estos 78
tests se manifiesta recién con el tiempo, y depende directamente del
ítem 6 ya pendiente en "Prioridades actuales" de `CLAUDE.md`: automatizar
`dbt run`/`dbt test`/`dbt snapshot` en un scheduler — sin corridas
regulares, Elementary no acumula el historial que necesita para que la
detección de anomalías tenga sentido.

## Estado

Cierra el pedido de "el resto de la Fase 5 (anomalías)". Con esto, las 3
dimensiones de calidad que el documento sugiere para validar el pipeline
de ingesta (volumen, frescura, distribución de columnas) están
implementadas — dos capas complementarias, no redundantes: reconciliación
exacta + freshness con umbrales fijos (PR #9, detecta desviaciones
duras/inmediatas) y Elementary (esta ronda, detecta desviaciones
estadísticas sutiles una vez que acumule historial).
