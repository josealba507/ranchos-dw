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
| **Timeliness** (oportunidad) | `dbt source freshness` sobre cada source de `sources.yml`, con `loaded_at_field: timestamp_registro` — alerta si una tabla no recibe datos nuevos en la ventana esperada (indicaría un trigger de sync roto, mismo tipo de incidente ya documentado en el proyecto operacional). |
| **Accuracy** (exactitud) | Reconciliación numérica vía `dbt_utils.equal_rowcount` / sumas de control entre staging y marts — mismo principio que los scripts `reconciliar-*.js` del proyecto operacional, pero como test automatizado en vez de script manual de un solo uso. |

**Regla dura:** ningún modelo de `marts/` se considera terminado sin al
menos `unique` + `not_null` en su clave primaria y `relationships` en cada
FK hacia una dimensión. Un PR que agregue un mart sin esos 3 tests como
mínimo no se mergea.

## 2. Data Modeling & Design — arquitectura de capas

```
sources (BigQuery: tb_dim_*, tb_fact_*)
    │
    ▼
staging (stg_*)        1:1 con la fuente, solo renombra/castea tipos,
                        NUNCA hace joins ni agregaciones. Vista.
    │
    ▼
intermediate (int_*)   joins/agregaciones reutilizables entre marts.
                        Ephemeral — no ensucia el dataset con tablas
                        que nadie consulta directo.
    │
    ▼
marts (dim_*/fct_*)     modelos finales, organizados por DOMINIO de
                        negocio (finanzas/leche/hato/veterinaria), no
                        por tabla fuente. Esto es lo único que BI/
                        Looker Studio debe consultar.
```

**Naming convention** (obligatoria, verificable por grep):
- `stg_<fuente>__<entidad>` — ej. `stg_ranchos__animales`
- `int_<descripcion>` — ej. `int_pesajes_agrupados_por_dia`
- `dim_<entidad>` / `fct_<entidad>` — mismo prefijo que ya usa el
  proyecto operacional en BigQuery (`tb_dim_*`/`tb_fact_*`), sin el
  prefijo `tb_` porque acá ya estamos dentro del contexto dbt.

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

Todo modelo (staging + marts, intermediate queda exento por ser
ephemeral/interno) debe tener:
- `description` a nivel de modelo en su `schema.yml`.
- `description` en cada columna que no sea 100% autoexplicativa por su
  nombre.
- Bloque `meta:` con al menos `owner: <email>` y `domain:
  finanzas|leche|hato|veterinaria`.

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
  **solo** al dataset de `marts` (schema `marts` en BigQuery, ver
  `+schema: marts` en `dbt_project.yml`) — nunca directo a `staging` ni
  a las tablas fuente `tb_dim_*`/`tb_fact_*`. Esto es lo que permite
  refactorizar la capa de staging sin romper dashboards ya publicados.

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
