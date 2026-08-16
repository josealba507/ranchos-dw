# RanchOS DW — Contexto del Proyecto

## Qué es esto
`ranchos-dw` es el **Data Warehouse analítico** de RanchOS, separado a
propósito de la app operacional. Transforma (vía dbt) los datos que la app
operacional ya sincroniza a BigQuery — este proyecto no captura datos por sí
mismo, solo los modela para reporting/analítica.

- **App operacional** (Firestore, Firebase Auth, Hosting, Cloud Functions que
  hacen el sync a BigQuery): repo `ranchos--app`
  (`C:\ALBA_ANALYTICS\GANADERIA\ranchos--app`), proyecto GCP `ranchos-7c313`.
  Producción: https://ranchos-7c313.web.app/
- **Data Warehouse analítico** (este repo): proyecto GCP
  `alba-analytics-ganaderia`.
- **Por qué están separados:** aislar costos/IAM/blast-radius entre lo
  operacional (app en vivo, usada por colaboradores de campo) y lo analítico
  (transformaciones, reporting, futuros dashboards) — que un cambio de
  modelado en el DW nunca pueda afectar la app en producción, y viceversa.
- Desarrollado y mantenido por la misma persona que `ranchos--app`
  (desarrollador con background de Ingeniería de Datos / Data Warehouse,
  aprendiendo dbt/analytics engineering sobre la marcha en este proyecto).

**Memoria de Claude Code separada a propósito:** este directorio tiene su
propio scope de memoria persistente, distinto del de `ranchos--app` — las
decisiones de arquitectura del DW no se mezclan con el historial de PRs de
la app operacional, y viceversa. Si necesitás contexto de cómo funciona la
app operacional (esquema de Firestore, qué Cloud Function sincroniza qué
tabla, etc.), consultá `CLAUDE.md` de `ranchos--app` — no lo dupliques acá.

## Stack
- **Transformación:** dbt-core 1.12.0 + adaptador dbt-bigquery 1.12.0.
- **Entorno Python:** venv dedicado en `.venv/` (nunca usar una instalación
  global de dbt) — `pip install -r requirements.txt` para recrearlo.
- **Conexión a BigQuery:** `~/.dbt/profiles.yml` (fuera del repo, no
  versionado), `method: oauth` vía Application Default Credentials
  (`gcloud auth application-default login`) — nunca un archivo de service
  account key en texto plano, mismo criterio de seguridad que
  `ranchos--app`.
- **Linting SQL:** sqlfluff, dialecto `bigquery`, config en `.sqlfluff`.
- **Editor:** VSCode, abrir la carpeta `dw_ranchos_app` como workspace raíz
  (no el repo completo de `ranchos--app`) para que la extensión de dbt
  detecte `dbt_project.yml`. Extensiones recomendadas ya declaradas en
  `.vscode/extensions.json`.
- **Repo:** https://github.com/josealba507/ranchos-dw (privado).

## Arquitectura de capas
5 capas + transversal, un dataset de BigQuery por capa (los permisos de
BigQuery se otorgan por dataset — es la razón de gobierno):

```
ranchos (L0 raw, fuera de dbt) → stg_ranchos (L1) → int_ranchos (L2,
solo snapshots — intermediate/ es ephemeral, sin dataset propio) →
marts_ranchos (L3, esquema estrella) → rpt_ranchos (L4, lo ÚNICO que BI/
reverse ETL debe consultar) · metadata_ranchos (transversal, reservado,
sin uso todavía)
```

Diagrama completo y detalle de cada dataset en
[`docs/dama_governance.md`](docs/dama_governance.md) sección 2. Decisiones
de por qué esta arquitectura y no otra (incluida la razón de separar L3 de
L4, que no es obvia) en
[`docs/fase2_arquitectura.md`](docs/fase2_arquitectura.md).

Reglas completas de gobernanza de datos (DAMA-DMBOK traducido a reglas
concretas de dbt — tests obligatorios por capa, naming, versionado
histórico, metadata, PII, lineage) en
[`docs/dama_governance.md`](docs/dama_governance.md). No repetir esas
reglas acá — ese documento es la fuente de verdad, este `CLAUDE.md` es
contexto de proyecto.

## Separación de entornos (dev/prod)
`macros/generate_schema_name.sql` antepone `dev_` a cada dataset cuando el
target es `dev` (el default en `profiles.yml` para trabajo local) — un
`dbt run` local nunca escribe sobre los datasets "reales" que algún día
consuma un dashboard. El target `prod` (`dbt run -t prod`) escribe sin
prefijo, reservado para cuando exista un pipeline/CI real.

## Versionado histórico — regla heredada de la app operacional
Las fact tables de `ranchos--app` **nunca hacen UPDATE in-place**: al
corregir un registro, la fila vigente pasa a `estado_registro='Corregido'`/
`'Anulado'` y se inserta una fila nueva `'Activo'` (SCD tipo 2 a nivel de
fila individual). **Todo modelo de `staging/` sobre una fact table debe
filtrar** `WHERE estado_registro = '{{ var("estado_registro_vigente") }}'`
(var ya definida en `dbt_project.yml`, valor `'Activo'`) — nunca hardcodear
el string suelto en el SQL. Si un modelo necesita el histórico completo
(auditoría, no reporting), debe nombrarse explícitamente
`int_<entidad>_historico_completo` y documentar por qué.

## Estado actual del proyecto
- **Scaffolding completo y verificado** (`dbt debug` conecta OK contra
  `alba-analytics-ganaderia`, `dbt parse` compila sin errores/warnings,
  `sqlfluff lint` limpio): estructura de carpetas, `dbt_project.yml`,
  `packages.yml` (`dbt_utils` + `dbt_expectations`), `.sqlfluff`, VSCode,
  modelo de referencia `stg_ranchos__animales` con el nivel mínimo de
  tests DAMA exigido (ver `docs/dama_governance.md` sección 1), `git init`
  + primer commit + repo en GitHub.
- **Migración histórica completa — hecha (2026-07-21).** Decisión
  confirmada con el usuario: `ranchos-7c313` sigue siendo la fuente
  operacional intocada (las Cloud Functions de `ranchos--app` NO se
  tocaron, ni su destino de sync ni ningún deploy); `alba-analytics-
  ganaderia` es una RÉPLICA analítica separada. Dataset `ranchos` creado
  (ubicación `US`, igual que el origen) y las 19 tablas
  (`tb_dim_*`/`tb_fact_*`) copiadas tabla por tabla vía `bq cp -f --sync`
  cross-project — conteos de filas verificados idénticos en ambos lados
  tras la copia (ej. `tb_fact_transacciones_financieras` 1151/1151,
  `tb_dim_animales` 170/170).
- **Hallazgo antes de migrar — dataset `Ganaderia` no documentado, ya
  eliminado:** `alba-analytics-ganaderia` NO estaba vacío como asumía
  este archivo — tenía un dataset `Ganaderia` (mayúscula, distinto de
  `ranchos`) con una tabla `tb_fact_transacciones_financieras_old` (1103
  filas, coincidente con el backfill de Finanzas de Alba Guerra) y una
  tabla externa `tb_stg_transacciones_sheets`, sin relación con este
  proyecto ni documentado en ningún CLAUDE.md. Confirmado con el usuario
  que era una prueba vieja — se borró por completo
  (`bq rm -r -f -d alba-analytics-ganaderia:Ganaderia`) antes de crear el
  dataset `ranchos` real, para no dejar basura de datos en el proyecto
  del DW.
- **2 discrepancias de esquema encontradas y corregidas al conectar por
  primera vez contra datos reales** (el modelo de referencia y
  `sources.yml` se habían escrito en base a lo documentado en
  `ranchos--app/CLAUDE.md`, no contra el esquema real verificado):
  1. `tb_dim_animales` NO tiene columna `foto_url` — el `ALTER TABLE`
     que el CLAUDE.md de `ranchos--app` documenta (PR #84) nunca se
     ejecutó en producción (confirmado además que
     `functions/src/index.ts` no referencia `foto_url` en ningún lado —
     no es un bug activo de sync, solo documentación desactualizada de
     ese repo, sin código nuevo esperando esa columna). Se quitó del
     `select` de `stg_ranchos__animales.sql`.
     **Resuelto en `ranchos--app` el 2026-07-23** (PR #109 de ese repo):
     `ALTER TABLE` + código de sync + backfill de los 84 animales con
     foto ya cargados, todo verificado en producción real (ver
     `ranchos--app/CLAUDE.md`). Este repo se puso al día el mismo día:
     `tb_dim_animales` se volvió a copiar completa
     (`bq cp -f --sync ranchos-7c313:ranchos.tb_dim_animales
     alba-analytics-ganaderia:ranchos.tb_dim_animales`, mismo método que
     la migración histórica original) — 170/170 filas, 84/84 con
     `foto_url`, verificado en ambos lados. `foto_url` volvió al
     `select` de `stg_ranchos__animales.sql` y a su documentación en
     `_ranchos__models.yml`; `dbt run` + `dbt test` (6/6) confirmados
     limpios contra la réplica actualizada.
  2. **Patrón de nombre de columna real, no `timestamp_registro` en
     todos lados:** las tablas DIM usan `fecha_creacion` (DATE); las
     FACT usan `timestamp_registro` (TIMESTAMP) — EXCEPTO
     `tb_fact_logs_actividad`, que usa `timestamp_evento`, y
     `tb_dim_fincas`, que usa `fecha_registro`. `sources.yml` tenía
     `loaded_at_field: timestamp_registro` mal puesto en `tb_dim_animales`
     (dim, no fact) — corregido a `fecha_creacion` — y en
     `tb_fact_logs_actividad` — corregido a `timestamp_evento`.
     Verificado con una query a
     `INFORMATION_SCHEMA.COLUMNS` contra las 19 tablas reales, no solo
     inferido. `stg_ranchos__animales.sql` y sus 6 tests DAMA corren y
     pasan contra los datos migrados reales (`dbt run` + `dbt test`
     limpios).
- **Actualización continua de la réplica (EL) — hecho (2026-07-24),
  3 veces al día (8am/1pm/8pm hora de Panamá).** Arquitectura híbrida,
  4 piezas en `alba-analytics-ganaderia` (proyecto del DW, ninguna toca
  `ranchos--app`):
  1. **Transfer config nativo** (BigQuery Data Transfer Service,
     `data_source=cross_region_copy`, "Dataset Copy") —
     `projects/702955643875/locations/us/transferConfigs/6a69a580-0000-2830-91fc-34c7e91a4873`.
     `overwrite_destination_table: true` (WRITE_TRUNCATE por tabla —
     necesario porque las fact tables versionan filas existentes en vez
     de solo agregar; una copia incremental de "solo filas nuevas"
     perdería las correcciones Activo→Corregido). `no_auto_scheduling`
     activado — el schedule interno de este transfer type tiene un
     **mínimo de 12 horas** (`minimumScheduleInterval: 43200s`,
     confirmado contra la API real, no documentado en ningún lado) que
     no alcanza para 3x/día, así que el disparo real no usa el
     scheduler propio del transfer.
  2. **Workflow `dw-trigger-el-transfer`** (`us-central1`, fuente
     versionada en [`infra/workflows/trigger_el_transfer.yaml`](infra/workflows/trigger_el_transfer.yaml)) —
     única pieza de lógica "propia" de todo el pipeline, y mínima: la
     API `startManualRuns` exige un `requestedRunTime` explícito (no
     acepta body vacío = "correlo ahora", confirmado empíricamente), y
     ese timestamp tiene que ser dinámico en cada disparo — un HTTP
     target de Cloud Scheduler no puede generarlo solo (body estático).
     El Workflow calcula `time.format(sys.now())` y llama a
     `startManualRuns`. Corre como la service account
     `dw-transfer-runner@alba-analytics-ganaderia.iam.gserviceaccount.com`,
     con un **rol IAM custom mínimo** (`dwTransferRunner`, solo
     `bigquery.transfers.get`+`bigquery.transfers.update` — no existe un
     rol predefinido más angosto que `roles/bigquery.admin` para esto,
     confirmado revisando permisos incluidos de los roles predefinidos).
  3. **Cloud Scheduler `dw-el-transfer-3x-diario`** (`us-central1`,
     cron `0 8,13,20 * * *`, `--time-zone=America/Panama`) — llama a
     `workflowexecutions.googleapis.com` para ejecutar el Workflow,
     usando OAuth con la service account
     `dw-scheduler-invoker@alba-analytics-ganaderia.iam.gserviceaccount.com`
     (`roles/workflows.invoker` a nivel proyecto — la API no tiene un
     comando `gcloud workflows add-iam-policy-binding` para scopearlo
     solo a este Workflow).
  - **APIs habilitadas como parte de este trabajo:** `iam`,
    `cloudscheduler`, `workflows`, `workflowexecutions` (`bigquery`/
    `bigquerydatatransfer` ya estaban habilitadas en ambos proyectos
    desde antes).
  - **Gotcha reproducible — demora de propagación de IAM:** tanto el
    primer intento de ejecución del Workflow (`IAM permission denied`
    pese al binding ya existente) como el primer disparo real de Cloud
    Scheduler fallaron en silencio por este motivo — un `add-iam-policy-
    binding` recién creado puede tardar ~1-2 min en propagarse antes de
    que el permiso sea efectivo. Ambos casos se resolvieron solos al
    reintentar sin cambiar nada. Si se vuelve a tocar IAM de estos
    recursos, esperar antes de asumir que algo está mal configurado.
  - **Verificado de punta a punta, 2 veces:** ejecución manual del
    Workflow (`gcloud workflows execute`) y disparo real del Cloud
    Scheduler job (`gcloud scheduler jobs run`) — ambos completaron
    `SUCCEEDED` en Workflow, `SUCCEEDED` en el transfer run de BigQuery,
    y con conteos de filas que subieron respecto al snapshot original
    (ej. `tb_fact_transacciones_financieras` 1151→1157), confirmando que
    trae datos reales de producción, no una copia estática.
  - **Hallazgo durante la verificación, sin acción requerida:** al
    revisar el dataset después de la primera corrida automática
    aparecieron 3 vistas (`VS_001_VENTA_LECHE`,
    `VS_002_TRANSACCION_FINANCIERA_AGRUPADA`,
    `VS_OO3_TRANSACCION_FINANCIERA_DIARIA`) no declaradas en
    `sources.yml` ni traídas por la copia (confirmado que no existen en
    `ranchos-7c313:ranchos`, el dataset origen). El usuario confirmó que
    las creó él mismo directo en BigQuery Console, prototipando reportes
    de Leche/Finanzas — no son parte del pipeline dbt todavía. Confirmado
    además, con una corrida real ya ejecutada, que `overwrite_destination_table`
    NO borra objetos del destino que no existen en el origen (solo
    sobreescribe por nombre coincidente) — estas 3 vistas sobrevivieron
    la corrida automática sin problema.
- **Ningún modelo de `marts/`/`reporting/` existe todavía** — solo el
  scaffold de carpetas (`.gitkeep`/config en `dbt_project.yml`). Ya no
  hay ningún bloqueante técnico para empezar a construirlos.
- **Especificación conceptual de DW por capas — Fases 0 y 2 completas
  (2026-08-13).** El usuario compartió un documento de especificación
  externo (no un pedido puntual) con un plan completo: Fase 0
  (inspección, sin código) → Fase 1 (nomenclatura, Punto de Control 1) →
  Fase 2 (arquitectura de capas) → Fase 3 (reglas de staging) → Fase 4
  (modelo dimensional, Punto de Control 2: 1 solo hecho de punta a
  punta antes de replicar el patrón) → Fase 5 (calidad) → Fase 6
  (alarmas) → Fase 7 (ML) → Fase 8 (optimización/costo). Regla del
  propio documento: cuando choca con una convención ya establecida de
  este proyecto, gana el proyecto — se reporta, no se resuelve en
  silencio.
  - **Fase 0** ([`docs/fase0_inspeccion.md`](docs/fase0_inspeccion.md)):
    inspección completa contra código real (no contra lo documentado en
    `ranchos--app/CLAUDE.md`, que ya demostró tener desfasajes — ver
    hallazgo de `foto_url` arriba). Hallazgos que cambian el resto del
    plan: (1) el pipeline de replicación NO es un patrón changelog/CDC
    — es DML con versionado (`estado_registro`) ya resuelto en origen,
    así que buena parte de la Fase 3 del documento (dedupe de
    changelog) no aplica tal cual; (2) el dinero NO son enteros en
    centavos como asume el documento — es `NUMERIC`/float, decisión ya
    tomada explícitamente en este proyecto (ver Insumos) — se mantiene
    `NUMERIC`, gana el proyecto; (3) **no hay `serverTimestamp()` en
    ningún lado de `ranchos--app`** — `timestamp_registro`/
    `fecha_creacion` se asignan con el reloj del DISPOSITIVO cliente,
    no del servidor, aunque el servidor sí tiene `context.timestamp`
    disponible y sin usar (solo como fallback que nunca se activa). No
    bloquea nada hoy; si se llega a la Fase 7 (ML), es un riesgo real
    de fuga temporal para capturas offline — requeriría un cambio
    aditivo en `functions/src/index.ts` de `ranchos--app`, con
    confirmación explícita cuando llegue el momento; (4) el dataset
    origen creció de 19 a 26 tablas desde la migración inicial (módulo
    de Insumos + catálogos nuevos de Hato); (5) 4 vistas (`VS_*`)
    creadas a mano en BigQuery Console, consumo real preexistente sin
    documentar.
  - **Fase 1** (Punto de Control 1, aprobado sin cambios): nomenclatura
    — español para negocio + inglés para prefijos técnicos, `snake_case`
    preservado 1:1 (Firestore ya usa snake_case acá, no hay conversión
    que hacer), prefijos dbt estándar (`stg_`/`int_`/`dim_`/`fct_`) ya
    en uso, singular en dims/facts (`dim_animal`, no `dim_animales`).
  - **Fase 2** ([`docs/fase2_arquitectura.md`](docs/fase2_arquitectura.md)):
    arquitectura de 5 capas + transversal aplicada (ver "Arquitectura de
    capas" arriba). Decisiones concretas: `ranchos` se mantiene como
    nombre de L0 sin rename (evita recrear el pipeline EL sin
    beneficio); se agregó el dominio `insumos` a `marts`/`reporting`
    (no existía en el scaffold original, el módulo es posterior); se
    agregó el dataset `rpt_ranchos` para L4 (corrige un hueco de mi
    propia propuesta de nomenclatura de la Fase 1, que lo había
    mezclado sin querer dentro de `marts_ranchos`); `dama_governance.md`
    sección 5 actualizada — BI se conecta a `rpt_ranchos` (L4), nunca a
    `marts_ranchos` (L3) directo. `sources.yml` reescrito con las 26
    tablas reales (de paso se corrigió `tb_dim_fincas`, que había
    quedado con el `loaded_at_field` mal puesto desde la sesión de
    migración anterior pese a estar identificado como excepción).
    Confirmado (no ejecutado, porque ya era así): la separación
    "proyecto de ingesta vs. proyecto de warehouse" que asume el
    documento no aplica tal cual acá — solo hay 2 proyectos GCP
    (`ranchos-7c313` operacional, `alba-analytics-ganaderia`
    analítico), y L0 ya vive en el proyecto de warehouse. Se recomendó
    explícitamente NO crear un tercer proyecto de "solo ingesta" — sin
    beneficio de gobierno real a este volumen/equipo de 1 persona.
  - **Fases 3-4, Punto de Control 2 — completo (2026-08-13)**
    ([`docs/checkpoint2_movimientos_insumos.md`](docs/checkpoint2_movimientos_insumos.md)):
    `movimientos_insumos` de punta a punta — staging (3 modelos) →
    snapshot SCD2 de `dim_insumo` (`snapshots/snapshot_insumo.sql`,
    estrategia `check` sobre categoria/presentacion/estado, no
    `timestamp`, porque no hay un campo confiable de última
    actualización — ver hallazgo de Fase 0) → intermediate (conforma
    cada movimiento con la versión de insumo vigente AL MOMENTO, no la
    actual) → `dim_finca`/`dim_fecha` (conformadas, `marts/comun/`) +
    `dim_insumo`/`fct_movimiento_insumo` (`marts/insumos/`) → 1 vista de
    reportería (`rpt_movimientos_insumo_recientes`). `dbt build`
    completo: 69/69 tests. Se agregó el dominio `comun` (dimensiones
    compartidas por más de un dominio de negocio) a `dbt_project.yml` y
    `dama_governance.md`, no contemplado en la Fase 2 original.
    - **2 problemas reales de datos encontrados y corregidos, no bugs de
      sintaxis:** (1) 20 filas huérfanas en producción real —
      `finca_asociada` con valores `TEST-DEBUG-*`/`TEST-VERIFICACION-*`,
      residuos de sesiones de verificación de `ranchos--app` nunca
      limpiados del todo (coincide con hallazgos previos ya documentados
      en el CLAUDE.md de ese repo) — excluidos en `staging/` con un
      filtro documentado, sin tocar `ranchos-7c313`; (2) el join
      punto-en-el-tiempo del intermediate no matcheaba NINGÚN movimiento
      real la primera vez, porque `dbt snapshot` no tiene histórico
      retroactivo — su primera corrida asigna `dbt_valid_from = ahora` a
      TODAS las versiones, y los 89 movimientos reales del proyecto son
      anteriores a esa corrida. Se detectó porque se verificaron los
      datos reales de la vista final (no solo que los tests pasaran) y
      salían con `insumo_nombre`/`categoria` vacíos — corregido con un
      fallback a la versión más antigua conocida del insumo cuando no
      hay coincidencia exacta de vigencia.
  - **Patrón replicado a los 4 dominios restantes — completo (2026-08-13):**
    Finanzas ([PR #4](https://github.com/josealba507/ranchos-dw/pull/4)),
    Leche ([PR #5](https://github.com/josealba507/ranchos-dw/pull/5)),
    Hato ([PR #6](https://github.com/josealba507/ranchos-dw/pull/6)),
    Veterinaria ([PR #7](https://github.com/josealba507/ranchos-dw/pull/7)).
    `dbt build` del proyecto completo: **322/322 tests, 0 errores** — 5
    dominios, 3 dimensiones con SCD2 (insumo, animal, lote), 26 tablas
    fuente cubiertas.
    - **Finanzas/Leche referencian la finca por `id_finca`, no
      `finca_asociada`** — a diferencia de Hato/Veterinaria/Insumos, otra
      inconsistencia de nombres de columna entre tablas del proyecto
      operacional (ver `docs/fase0_inspeccion.md`).
    - **`macros/filtros_datos_prueba.sql`** centraliza la exclusión de
      datos de prueba de sesiones de verificación de `ranchos--app` que
      quedaron en producción — 2 macros (por `finca_asociada`/prefijo
      `TEST-`, y por `id_finca`/lista explícita). Un caso
      (`finca_trebol`, 4 transacciones con apariencia 100% real: canal
      `Web-App-Online`, montos reales) se investigó a fondo antes de
      confirmarlo como dato de prueba con el usuario, no producción real
      sin sincronizar.
    - **Hallazgo real más importante de esta ronda —
      `macros/normalizar_mojibake.sql`:** 192/234 filas de
      `tb_fact_palpamientos.resultado` y 53/128 de
      `tb_fact_pesaje_leche.ordeno` en producción real tienen UTF-8 mal
      re-codificado ("PreÃ±ada" en vez de "Preñada", "MaÃ±ana" en vez de
      "Mañana") — probablemente del backfill histórico inicial desde
      Excel (`backfill-hato-alba-guerra.js` en `ranchos--app`). Sin
      corregirlo, cualquier agregación por esas columnas trataba el
      mismo valor de negocio como 2 distintos. Normalizado en staging
      (sin tocar `ranchos-7c313`), verificado con matemática exacta
      contra BigQuery directo. **Pendiente de decidir con el usuario:**
      si vale la pena corregir esto también en el origen
      (`ranchos-7c313`), o si normalizar en el warehouse es suficiente.
    - **Dominio Hato — 2 dimensiones historizadas SCD2**
      (`snapshot_animal`/`snapshot_lote`), tal como pide explícitamente
      la Fase 4 del documento para "Animal" y "Lote / hato".
      `dim_categoria_animal`/`dim_motivo_salida`/`dim_veterinario`/
      `dim_medicina`/`dim_motivo_tratamiento`/`dim_catalogo_finanzas`
      quedaron sin historización — el documento no las nombra
      explícitamente para SCD2, a diferencia de animal/lote/insumo.
    - **`tb_fact_salidas` está vacía en producción real** (0 filas) —
      `rpt_salidas_recientes` no tiene datos todavía, no es un bug.
    - **Sin enriquecimiento punto-en-el-tiempo en `fct_parto`/
      `fct_salida`** (a diferencia de `fct_movimiento_insumo` del
      Checkpoint 2) — decisión de alcance explícita, documentada en cada
      PR, no hay caso de negocio que lo requiera todavía.

## Prioridades actuales (en orden)
1. ~~Resolver la migración de datos~~ — **hecho** (histórico completo +
   actualización continua 3x/día, ver "Estado actual" arriba).
2. ~~Fases 0-4 del documento de especificación (arquitectura completa +
   patrón replicado a los 5 dominios)~~ — **hecho** (2026-08-13, ver
   "Estado actual" arriba). `dbt build` del proyecto completo: 322/322
   tests.
3. ~~Fase 5 — reconciliación raw vs. Firestore~~ — **hecho, parcial
   (2026-08-13)** ([`docs/fase5_reconciliacion_raw.md`](docs/fase5_reconciliacion_raw.md)):
   26 tests de reconciliación de conteo (`raw` vs. source nuevo
   `ranchos_operacional`, que apunta a `ranchos-7c313` real — no una
   réplica) confirman que la réplica EL es 100% fiel hoy. `dbt source
   freshness` pasó de "no computa nada" (sin umbrales configurados) a
   funcionar con 2 niveles (dims 14d/45d, facts 5d/14d) — encontrado y
   corregido de paso un bug real: las columnas `DATE` de las dims
   rompían el mecanismo de freshness de dbt-bigquery, que exige
   `TIMESTAMP`. `metadata_ranchos` (reservado desde la Fase 2) ya
   recibe escrituras reales vía `store_failures`, confirmado con `bq ls`.
   `dbt build`: 348/348 tests.
   - ~~Detección automática de anomalías~~ — **hecho (2026-08-13)**
     ([`docs/fase5_anomalias_elementary.md`](docs/fase5_anomalias_elementary.md)):
     paquete `elementary-data/elementary` (0.25.1), elegido sobre
     construir algo casero con `dbt_expectations` — confirmado con el
     usuario. Escribe en `metadata_ranchos` (junto a la reconciliación).
     3 tests (`volume_anomalies`/`freshness_anomalies`/
     `all_columns_anomalies`) aplicados a las 26 tablas de `sources.yml`
     — 78 tests, todos PASS en el rollout completo. **Sin historial
     acumulado todavía no detecta anomalías reales** — depende
     directamente del ítem 6 de abajo (automatizar corridas de dbt).
     Hallazgo de paso: el paquete registra sus propios hooks
     `on-run-start`/`on-run-end` solo, sin necesitar configuración
     manual en `dbt_project.yml`.
   - ~~Exactitud del ledger de Insumos vs. saldo cacheado~~ — **hecho
     (2026-08-13)** ([`docs/fase5_exactitud_insumos.md`](docs/fase5_exactitud_insumos.md)):
     `tests/exactitud_existencia_insumo_vs_ledger.sql` reconcilia
     `SUM(cantidad_base)` de `movimientos_insumos` contra
     `existencia_actual` de `catalogo_insumos` — cierra la fila
     "Accuracy (exactitud)" de `docs/dama_governance.md`, hasta ahora
     aspiracional (sin test real detrás). Confirmado empíricamente antes
     de escribirlo (no asumido) que `cantidad_base` ya trae su propio
     signo por `tipo_movimiento` — no hace falta signar en el test.
     Consistencia (huérfanos fact→dim) ya estaba cubierta por los tests
     `relationships` nativos desde que se construyó el dominio Insumos —
     no requirió trabajo nuevo. Con esto no queda ninguna dimensión de
     `dama_governance.md` sin al menos un test real que la implemente —
     Fase 5 queda completa.
   - Fase 6 (alarmas): separar alarmas técnicas (canal del equipo) de
     alarmas de negocio (reverse ETL hacia una colección de Firestore —
     requiere tocar `ranchos--app`, con confirmación explícita cuando
     llegue el momento).
   - Fase 7 (ML): bloqueada parcialmente por el hallazgo de
     `timestamp_registro` sin `serverTimestamp()` real (ver "Estado
     actual" arriba) — requiere decidir primero si se acepta la
     aproximación actual o se pide un cambio aditivo en
     `functions/src/index.ts` de `ranchos--app`.
   - Fase 8 (optimización/costo): particionado ya viene heredado de las
     fact tables origen; falta evaluar vistas materializadas, policy
     tags sobre columnas de costo, y vistas autorizadas para L4.
4. **Pendiente de decidir con el usuario, no bloqueante:** si el
   mojibake encontrado en `resultado`/`ordeno` (ver "Estado actual")
   vale la pena corregirlo también en `ranchos-7c313` (origen), o si
   normalizarlo en el warehouse alcanza.
5. `dbt docs generate` + `dbt docs serve` como catálogo de datos
   navegable — ya hay suficientes modelos (37) para que valga la pena.
6. ~~Automatizar `dbt run`/`dbt test`/`dbt snapshot`~~ — **hecho
   (2026-08-16)** ([`docs/fase_orquestacion_dbt.md`](docs/fase_orquestacion_dbt.md)):
   `dbt build --target prod` corre dentro de un Cloud Run Job
   (`dw-dbt-build`), disparado por el mismo Workflow que ya orquestaba
   la sync EL — ahora ESPERA (polling) a que la sync termine antes de
   disparar dbt, en vez de correr en un momento arbitrario. Esto
   también resuelve de raíz el falso positivo transitorio de
   reconciliación ya documentado (`docs/fase5_reconciliacion_raw.md`,
   `docs/fase5_exactitud_insumos.md`). La imagen del contenedor se
   reconstruye y redespliega sola en cada push a `main` (Cloud Build
   trigger conectado a GitHub). Primera vez que el target `prod` corre
   de verdad — verificado en producción real (`PASS=458 ERROR=0`,
   datasets `stg_ranchos`/`marts_ranchos`/etc. sin prefijo `dev_`
   confirmados vía `bq ls`). **Pendiente, a propósito, fuera de esta
   entrega:** alertas cuando el `dbt build` programado falla — queda
   para la Fase 6 (alarmas), que ya estaba prevista como trabajo
   separado.

## Cómo trabajar conmigo en este proyecto
Mismo criterio de colaboración que ya está establecido en `ranchos--app`
(mismo desarrollador, mismo estilo de trabajo):
- Soy el único desarrollador. Explicá el *por qué* de cada cambio, no solo
  el qué — estoy aprendiendo dbt/analytics engineering sobre la marcha, mi
  fuerte es datos pero no necesariamente las convenciones específicas del
  ecosistema dbt.
- Antes de tocar cualquier cosa que cruce a `ranchos--app` (permisos IAM,
  `functions/src/index.ts`, deploys de esa app) o que sea un
  DROP/ALTER/migración destructiva sobre `alba-analytics-ganaderia`,
  mostrame el cambio y esperá confirmación explícita — mismo nivel de
  cautela que ya rige en `ranchos--app` para producción.
- Commits pequeños y descriptivos. No mezclar refactors grandes con fixes.
- Nunca subir ni imprimir claves de servicio, API keys, ni archivos
  `.env`/`serviceAccountKey.json` — verificar que estén en `.gitignore`
  (ya cubierto, pero revalidar si se agrega algo nuevo que las use).
- Antes de crear un mart o modelo nuevo, aplicar como mínimo los 3 tests
  de `docs/dama_governance.md` sección 1 (`unique`+`not_null` en PK,
  `relationships` en cada FK) — no es opcional, es la regla dura del
  proyecto.
- Todo modelo debe usar `{{ ref(...) }}`/`{{ source(...) }}`, nunca un
  nombre de tabla crudo en un `FROM` — es lo que mantiene el grafo de
  lineage (`dbt docs generate`) confiable.

## Pendiente de definir (preguntar si hace falta)
- Herramienta de BI/reporting final (Looker Studio es la opción más
  natural por ser gratis y de Google, pero no está decidido) — recién
  relevante una vez existan marts reales para conectar.
- Si el proyecto va a necesitar CI/CD propio (GitHub Actions corriendo
  `dbt build` en cada PR) o si alcanza con correrlo a mano por ahora,
  dado que es un solo desarrollador.
