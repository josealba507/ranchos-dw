# Fase 2 — Arquitectura de capas

**Fecha:** 2026-08-13
**Depende de:** `docs/fase0_inspeccion.md` (hallazgos) — Punto de control 1
aprobado sin cambios sobre la propuesta de nomenclatura ahí presentada.

---

## Separación de proyectos — confirmación, no migración

El documento de especificación pide confirmar que **raw vive en "el
proyecto de ingesta"** y las capas transformadas en "el proyecto de
warehouse". Esa topología de 3 proyectos (ingesta / warehouse / consumo)
**no es la que existe ni la que tiene sentido para este proyecto** — se
reporta acá en vez de forzarla en silencio (regla 4 del documento):

- Solo existen **2 proyectos GCP relevantes**: `ranchos-7c313`
  (operacional — Firestore, Auth, Hosting, Cloud Functions) y
  `alba-analytics-ganaderia` (analítico — todo lo que toca este repo).
- **La capa L0 (raw), tal como la usa este repo, ya vive en el proyecto de
  warehouse** (`alba-analytics-ganaderia:ranchos`), no en un proyecto de
  ingesta separado. El dataset `ranchos` de `ranchos-7c313` es el
  *origen* real de los datos (poblado por las Cloud Functions
  operacionales), pero no es "un proyecto de ingesta" dedicado — es el
  propio proyecto operacional, que seguiría existiendo con o sin este
  data warehouse.
- **Recomendación: no crear un tercer proyecto.** Con 1 solo desarrollador
  y el volumen de datos actual (26 tablas, la más grande con ~1150 filas),
  separar "ingesta" de "warehouse" en dos proyectos GCP distintos
  agregaría fricción de IAM/facturación sin ningún beneficio de gobierno
  real — el mismo beneficio (aislar operacional de analítico) ya se
  logra con la separación de 2 proyectos que existe hoy. Si el volumen o
  el equipo crecen, esto se puede revisar — no es una decisión
  irreversible, solo la más simple que cubre la necesidad actual.
- **Esto ya estaba correctamente separado antes de esta fase** (migración
  hecha en una sesión anterior de este mismo repo) — no hay ninguna
  migración pendiente de ejecutar acá.

## Arquitectura de capas — decisiones finales

Cinco capas + transversal, cada una en su propio dataset de BigQuery (la
razón de gobierno del propio documento: los permisos de BigQuery se
otorgan por dataset). Detalle completo y diagrama en
`docs/dama_governance.md` sección 2 — acá solo el resumen de decisiones:

| Capa | Mecanismo dbt | Dataset | Decisión y por qué |
|---|---|---|---|
| L0 raw | fuera de dbt (`sources.yml`) | `ranchos` | **Se mantiene el nombre tal cual, sin rename a `raw_ranchos`** — es el nombre real que ya usa el transfer config de BigQuery Data Transfer Service y `sources.yml`; renombrarlo hubiera significado recrear el pipeline EL entero sin ningún beneficio (era la opción "sin rework" que la Fase 0 dejó planteada como alternativa válida). |
| L1 staging | `models/staging/`, view | `stg_ranchos` | Ya en uso desde el modelo de referencia — solo se renombró de `staging` (genérico) a `stg_ranchos` (consistente con el resto de la tabla). |
| L2 integración (reglas de negocio) | `models/intermediate/`, ephemeral | *(sin dataset — no persiste)* | Sin cambios de esta fase. |
| L2 integración (historización SCD2) | `snapshots/`, table | `int_ranchos` | **Nuevo en esta fase.** El documento asigna "historización de dimensiones que cambian" a L2 — el mecanismo nativo de dbt para eso es `snapshot`, no un modelo `intermediate` más (un snapshot es una tabla que dbt mantiene automáticamente con `dbt_valid_from`/`dbt_valid_to`, no SQL que se recalcula cada vez). Reservado para `dim_animal`/`dim_lote`/`dim_insumo` cuando se implementen (Fase 4). |
| L3 marts | `models/marts/<dominio>/`, table | `marts_ranchos` | Renombrado de `marts` (genérico). **Se agregó el dominio `insumos`** (`models/marts/insumos/`) — no existía en el scaffold original porque el módulo de Insumos de `ranchos--app` es posterior al primer commit de este repo. Sin ese dominio, el hecho recomendado para el Punto de Control 2 (`movimientos_insumos`) no tendría dónde vivir. |
| L4 reporting | `models/reporting/<dominio>/`, view (default) | `rpt_ranchos` | **Nuevo — corrige un hueco de mi propia propuesta de la Fase 0.** La tabla de nomenclatura que presenté en el Punto de Control 1 listaba datasets para L0-L3 + transversal, mezclando L4 dentro de "marts" por descuido. El propio documento es explícito en que L3 y L4 son capas distintas con público distinto (L3 = motor técnico del esquema estrella; L4 = superficie curada que de verdad consulta BI/reverse ETL) — separarlas en datasets distintos es lo que permite el punto de gobierno central del documento: *"Quien hace reportes accede a L4 y nada más"*. `docs/dama_governance.md` sección 5 se actualizó para reflejar que BI se conecta a `rpt_ranchos`, no a `marts_ranchos`. |
| Transversal — metadata | *(sin modelos propios todavía)* | `metadata_ranchos` | Dataset reservado, documentado, sin escrituras — se activa recién en la Fase 5 (calidad de datos) del plan, cuando se configure `store_failures`. |

## Cambios aplicados en esta fase

- `dbt_project.yml`: datasets renombrados/agregados por capa (tabla de
  arriba), nuevo bloque `snapshots:`, dominio `insumos` sumado a `marts`
  y a la nueva sección `reporting`.
- `models/staging/ranchos/_ranchos__sources.yml`: reescrito completo — de
  19 a **26 tablas** (las 7 que se sumaron a producción después de la
  migración inicial, ver `docs/fase0_inspeccion.md` sección 0.4), cada
  una con su `loaded_at_field` verificado contra
  `INFORMATION_SCHEMA.COLUMNS` real, no copiado de otra tabla. Se
  corrigió de paso `tb_dim_fincas` (`fecha_registro`, no
  `fecha_creacion`), que había quedado sin corregir en la sesión de
  migración anterior pese a estar identificado como excepción en el
  informe de Fase 0.
- `docs/dama_governance.md`: diagrama de arquitectura extendido a 5 capas
  + transversal, sección 5 (gobierno de acceso) actualizada para que BI
  apunte a L4 en vez de L3, dominio `insumos` sumado en 2 lugares.
- Carpetas nuevas: `models/reporting/`, `models/marts/insumos/`.
- Limpieza: dataset `dev_staging` (huérfano tras el rename a
  `dev_stg_ranchos`) eliminado — estaba vacío salvo por la vista de
  desarrollo que ya se reconstruyó en el dataset nuevo.

## Verificación

- `dbt parse`: limpio (solo warnings esperados de "unused configuration
  paths" para las carpetas de dominio que todavía no tienen modelos —
  mismo tipo de warning tolerado ya antes de esta fase).
- `dbt run --select staging` + `dbt test --select staging`: el modelo de
  referencia sigue construyendo y sus 6 tests DAMA siguen pasando contra
  el dataset renombrado (`dev_stg_ranchos`).
- `sources.yml` ahora declara **26 sources** (confirmado en el log de
  `dbt run`), no 19.

## Estado

Fase 2 completa. Sin punto de control obligatorio en este punto del
documento — sigo hacia la Fase 3 (reglas de staging, ya aplicables sin
cambios dado que el mecanismo de deduplicación que asume el documento no
existe en este proyecto, ver Fase 0) y hacia la Fase 4, donde me detengo
en el Punto de Control 2 obligatorio (un solo hecho de punta a punta)
antes de replicar el patrón al resto de los dominios.
