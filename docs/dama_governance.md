# Gobernanza de datos — RanchOS DW (principios DAMA-DMBOK)

Este documento traduce las áreas de conocimiento del **DAMA-DMBOK** (Data
Management Body of Knowledge) a reglas concretas y verificables dentro de
este proyecto dbt. No es teoría aparte — cada regla de acá tiene su
contraparte exacta en `dbt_project.yml`, un test en `models/**/*.yml`, o una
convención de nombres que se puede grepear.

## 1. Data Quality (calidad de dato) — las 6 dimensiones DAMA

Cada dimensión de calidad se implementa como un tipo de test dbt específico,
no como una idea abstracta:

| Dimensión DAMA | Cómo se aplica en este repo |
|---|---|
| **Completeness** (completitud) | `not_null` en toda columna que el negocio considera obligatoria; `dbt_expectations.expect_column_values_to_not_be_null` con umbral de tolerancia (`row_condition`) donde un campo es opcional pero no debería estar vacío en >X% de los casos (ej. `arete` en animales de más de 6 meses). |
| **Uniqueness** (unicidad) | `unique` en toda PK (`id_registro`, `id_animal`, etc.); `dbt_utils.unique_combination_of_columns` cuando la unicidad es compuesta (ej. un animal no puede tener 2 pesajes con el mismo `id_animal` + `fecha_pesaje` + `ordeno`). |
| **Validity** (validez) | `accepted_values` en toda columna categórica (`sexo`, `estado`, `resultado`, `tipo_transaccion`) — la lista de valores permitidos vive en el test, así un valor nuevo no documentado rompe el build en vez de colarse en un dashboard. |
| **Consistency** (consistencia) | `relationships` test entre fact y dim (ej. `id_animal` de `fct_pesaje_leche` debe existir en `dim_animales`) — detecta huérfanos que en Firestore/BigQuery hoy no tienen FK real. |
| **Timeliness** (oportunidad) | `dbt source freshness` sobre cada source de `sources.yml`, con `loaded_at_field` apuntando a la columna de timestamp real de cada tabla — alerta si una tabla no recibe datos nuevos en la ventana esperada (indicaría un trigger de sync roto, mismo tipo de incidente ya documentado en el proyecto operacional). **El nombre de esa columna NO es uniforme entre tablas** (verificado contra `INFORMATION_SCHEMA.COLUMNS` real, no asumido): la mayoría de las `tb_fact_*` usan `timestamp_registro`, pero `tb_fact_logs_actividad` usa `timestamp_evento`; la mayoría de las `tb_dim_*` usan `fecha_creacion`, pero `tb_dim_fincas` usa `fecha_registro`. Verificar el esquema real antes de copiar el patrón de otra tabla — ver `_ranchos__sources.yml` para los valores ya confirmados. **Umbrales configurados desde el 2026-08-13** (ver `docs/fase5_reconciliacion_raw.md`): 14d/45d warn/error por defecto (dims/catálogos, bajo movimiento por diseño), 5d/14d override en cada `tb_fact_*` (captura activa) — las columnas `DATE` (dims) van envueltas en `cast(... as timestamp)` en `loaded_at_field`, porque el mecanismo de freshness de dbt-bigquery exige TIMESTAMP y falla con `Database Error` si no. |
| **Conciliación** | `tests/generic/test_reconciliacion_conteo_raw_vs_operacional.sql`, aplicado a las 26 tablas de `sources.yml` — compara el conteo exacto de filas de cada tabla en `raw` (L0, la réplica en `alba-analytics-ganaderia`) contra la misma tabla en el source `ranchos_operacional` (apunta a `ranchos-7c313`, la fuente real). Responde directamente "¿se copió Firestore hasta acá?" — ver `docs/fase5_reconciliacion_raw.md`. `store_failures: true` + `schema: metadata_ranchos` en los 26 — confirmado con `bq ls` que crea las 26 tablas de resultado en cada corrida, no solo configurado. |
| **Accuracy** (exactitud) | Reconciliación numérica vía `dbt_utils.equal_rowcount` / sumas de control entre staging y marts — mismo principio que los scripts `reconciliar-*.js` del proyecto operacional, pero como test automatizado en vez de script manual de un solo uso. |

**Regla dura:** ningún modelo de `marts/` se considera terminado sin al
menos `unique` + `not_null` en su clave primaria y `relationships` en cada
FK hacia una dimensión. Un PR que agregue un mart sin esos 3 tests como
mínimo no se mergea.

## 2. Data Modeling & Design — arquitectura de capas

Arquitectura completa de 5 capas + transversal (detalle de decisiones en
`docs/fase2_arquitectura.md`) — un dataset de BigQuery por capa, porque en
BigQuery los permisos se otorgan por dataset:

```
L0  raw (dataset "ranchos", FUERA de dbt)
    Réplica exacta de ranchos-7c313:ranchos, poblada por el pipeline EL
    (BigQuery Data Transfer + Workflow, 3x/día). Inmutable, sin retención.
    │
    ▼
L1  staging (stg_*, dataset "stg_ranchos")     VIEW
    1:1 con la fuente, solo renombra/castea tipos. NUNCA joins ni
    agregaciones. Nunca se consulta directo desde BI.
    │
    ▼
L2  integración — dos mecanismos, mismo layer conceptual:
    - intermediate (int_*, EPHEMERAL, sin dataset propio)
      joins/reglas de negocio/conciliación reutilizables entre marts.
    - snapshots (dataset "int_ranchos")          TABLE
      historización SCD tipo 2 de dimensiones que cambian de estado
      (animal, lote, insumo) — usa el mecanismo nativo `dbt snapshot`,
      no un modelo intermediate más.
    │
    ▼
L3  marts (dim_*/fct_*, dataset "marts_ranchos")     TABLE
    Modelo dimensional, esquema estrella, organizado por DOMINIO de
    negocio (finanzas/leche/hato/veterinaria/insumos), no por tabla
    fuente. Es el motor del esquema estrella — técnico, no lo
    consulta BI directo (ver sección 5).
    │
    ▼
L4  reporting (dataset "rpt_ranchos")     VIEW (default) / TABLE (features, alertas)
    Vistas de negocio con control de acceso sobre marts_ranchos, tablas
    de features para ML, tablas de alertas destinadas a reverse ETL
    (ver Fase 6 del documento de especificación). Es lo ÚNICO que BI/
    Looker Studio/reverse ETL deben consultar.

Transversal: metadata (dataset "metadata_ranchos")
    Resultados de tests persistidos, histórico de freshness, auditoría
    de ejecuciones. Se activa en la sección 1 de este documento
    (Fase 5 del plan) — dataset reservado desde ya, sin escrituras
    todavía.
```

**Naming convention** (obligatoria, verificable por grep):
- `stg_<fuente>__<entidad>` — ej. `stg_ranchos__animales`
- `int_<descripcion>` — ej. `int_pesajes_agrupados_por_dia`
- `dim_<entidad>` / `fct_<entidad>` — mismo prefijo que ya usa el
  proyecto operacional en BigQuery (`tb_dim_*`/`tb_fact_*`), sin el
  prefijo `tb_` porque acá ya estamos dentro del contexto dbt. Singular,
  no plural (`dim_animal`, no `dim_animales`) — ver
  `docs/fase0_inspeccion.md` para la justificación completa de esta
  elección frente a la alternativa (plural, como ya usa Firestore/raw).
- `rpt_<descripcion>` en L4 para vistas de negocio; `ft_<descripcion>`
  para tablas de features de ML; `alerta_<descripcion>` para tablas
  destinadas a reverse ETL — las 3 conviven en `marts/reporting/`
  organizadas por dominio, igual que L3.

## 3. Data Lifecycle Management — versionado histórico

El proyecto operacional (RanchOS) **nunca hace UPDATE in-place** sobre una
fact table — al corregir un registro, la fila vigente pasa a
`estado_registro='Corregido'`/`'Anulado'` y se inserta una fila nueva
`'Activo'` (ver `CLAUDE.md` del repo `ranchos--app`, sección Analítica).
Esto es, en términos DAMA, una implementación de **Slowly Changing
Dimension tipo 2 a nivel de fila individual** aplicada a fact tables.

**Regla dura:** todo modelo de `staging/` sobre una fact table
(`tb_fact_*`) DEBE filtrar `WHERE estado_registro = '{{
var("estado_registro_vigente") }}'` (la var ya definida en
`dbt_project.yml`) — nunca hardcodear el string `'Activo'` suelto en el
SQL. Si un modelo necesita el histórico completo (auditoría, no
reporting), debe declararlo explícitamente en su nombre
(`int_<entidad>_historico_completo`) y documentar por qué en su
`description`.

## 4. Metadata Management — documentación como código

Todo modelo (staging + marts + reporting; intermediate queda exento por
ser ephemeral/interno) debe tener:
- `description` a nivel de modelo en su `schema.yml`.
- `description` en cada columna que no sea 100% autoexplicativa por su
  nombre.
- Bloque `meta:` con al menos `owner: <email>` y `domain:
  comun|finanzas|leche|hato|veterinaria|insumos` (`comun` es para
  dimensiones conformadas — compartidas por más de un dominio de
  negocio, ej. `dim_finca`/`dim_fecha` — no para hechos).

`dbt docs generate` + `dbt docs serve` es la fuente de verdad del
catálogo de datos — no se mantiene documentación de esquema en un doc
separado que se desincroniza.

## 5. Data Governance — PII y control de acceso

- Ningún dato personal (email, nombre completo de usuario) se expone en
  `marts/` salvo que el mart lo necesite explícitamente para el reporte
  (ej. auditoría por usuario) — en ese caso, la columna se marca
  `meta: {pii: true}` en el `schema.yml`, para que a futuro se pueda
  automatizar un chequeo de "no exponer PII en marts públicos" con un
  test custom.
- BI/Looker Studio/cualquier herramienta de reporting se conecta
  **solo** al dataset `rpt_ranchos` (L4, ver `+schema: rpt_ranchos` en
  `dbt_project.yml`) — nunca directo a `marts_ranchos` (L3), `stg_ranchos`
  ni a las tablas fuente `tb_dim_*`/`tb_fact_*` de `ranchos` (L0). L3 es
  el motor técnico del esquema estrella; L4 es la superficie curada con
  control de acceso (vistas autorizadas, columnas de costo con policy
  tags — ver Fase 8 del documento de especificación) que de verdad
  expone el negocio. Esto es lo que permite refactorizar staging Y marts
  sin romper dashboards ya publicados, y lo que hace posible dar acceso
  de reporting sin dar acceso a las 26 tablas fuente crudas.

## 6. Data Lineage — trazabilidad end-to-end

`dbt docs generate` produce el grafo de lineage automáticamente a
partir de los `ref()`/`source()` de cada modelo — **nunca usar el
nombre de tabla crudo en un `FROM`**, siempre `{{ ref('...') }}` o
`{{ source('...', '...') }}`, incluso dentro de `intermediate/`. Es la
única forma de que el grafo de lineage (y `dbt source freshness`) sea
confiable.

Los consumidores finales (dashboards, reportes) se declaran en
`models/exposures.yml` — así el lineage no termina en el último mart,
sino que llega hasta el dashboard real que lo consume, y `dbt run
--select +exposure:<nombre>` permite saber exactamente qué modelos hay
que correr para refrescar un reporte específico.

## 7. Referencia rápida — qué NO hacer

- No consultar `tb_dim_*`/`tb_fact_*` (las tablas fuente) directo desde
  un mart — siempre pasar por `staging/` primero, aunque sea un
  passthrough casi 1:1.
- No hardcodear nombres de proyecto/dataset de BigQuery en el SQL de un
  modelo — usar `{{ source(...) }}`/`{{ ref(...) }}`, que resuelven el
  proyecto/dataset según `profiles.yml`/`dbt_project.yml`.
- No crear un mart sin al menos los 3 tests mínimos (sección 1).
- No consumir el histórico completo de una fact table sin filtrar
  `estado_registro` a menos que sea un caso explícito de auditoría,
  documentado como tal.
