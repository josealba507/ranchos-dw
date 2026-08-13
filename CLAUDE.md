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
  - **Siguiente paso:** Fase 3 (reglas de staging, sin Punto de Control
    propio) hacia la Fase 4, deteniéndome en el Punto de Control 2
    obligatorio — 1 solo hecho de punta a punta (candidato sugerido por
    el propio documento: `movimientos_insumos`, por ser el hecho
    transaccional más simple de declarar en una frase) antes de
    replicar el patrón a los demás dominios.

## Prioridades actuales (en orden)
1. ~~Resolver la migración de datos~~ — **hecho** (histórico completo
   migrado 2026-07-21 + actualización continua 3x/día vía Cloud
   Scheduler + Workflow + BigQuery Data Transfer Service, implementado
   2026-07-24, ver "Estado actual" arriba). No queda ninguna sub-parte
   pendiente de este ítem.
2. **Conducido ahora por el plan de fases del documento de especificación**
   (ver "Estado actual" arriba) — reemplaza este ítem genérico. Fases 0-2
   completas; próximo: Fase 3 (reglas de staging) → Fase 4, Punto de
   Control 2 (`movimientos_insumos` de punta a punta: staging → snapshot/
   intermediate → dims → fact → 1 vista de `reporting/`) antes de
   construir la capa `staging/` completa (26 tablas de `sources.yml`,
   hoy solo hay 1 modelo de referencia) y replicar el patrón al resto de
   los dominios.
3. Primeros marts por dominio más allá del hecho de control —
   probablemente `marts/finanzas` y `marts/leche` después, por ser los
   dominios con más historia de datos ya cargada en el proyecto
   operacional (backfills de Ganadera Alba Guerra, ver
   `ranchos--app/CLAUDE.md`).
4. `dbt docs generate` + `dbt docs serve` como catálogo de datos navegable,
   una vez haya suficientes modelos para que valga la pena.
5. Evaluar automatizar `dbt run`/`dbt test` (Cloud Build, GitHub Actions,
   o un scheduler simple) en vez de correrlo siempre a mano desde local —
   todavía sin decidir, no hay urgencia mientras el proyecto sea de un solo
   desarrollador. Probablemente se resuelve junto con la decisión de
   actualización continua de la réplica (ítem 1) si se elige un job
   propio en vez de BigQuery Data Transfer Service nativo.

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
