# RanchOS DW (`ranchos_dw`)

Data Warehouse analítico de RanchOS — proyecto dbt separado de la app
operacional (`ranchos--app`), siguiendo la separación operacional/analítica
descrita en `CLAUDE.md` de ese repo. Este proyecto **transforma** los datos
que las Cloud Functions de `ranchos--app` ya sincronizan a BigQuery; no
captura datos por sí mismo.

- **App operacional (Firestore + Firebase + BigQuery ingest):** repo
  `ranchos--app`, proyecto GCP `ranchos-7c313`.
- **Data Warehouse analítico (este repo):** proyecto GCP
  `alba-analytics-ganaderia`.
- **Gobernanza de datos aplicada:** ver [`docs/dama_governance.md`](docs/dama_governance.md)
  — traduce DAMA-DMBOK a reglas concretas (tests obligatorios, naming,
  materialización por capa, versionado histórico, PII, lineage).

## Estructura

```
models/
  staging/<fuente>/     stg_*  — 1:1 con la tabla fuente, vista (dataset stg_ranchos)
  intermediate/          int_*  — joins/reglas de negocio reutilizables, ephemeral (sin dataset propio)
  marts/<dominio>/       dim_*/fct_* — modelo dimensional, tabla (dataset marts_ranchos)
    finanzas/
    leche/
    hato/
    veterinaria/
    insumos/
  reporting/<dominio>/   vistas de negocio + features ML + alertas reverse ETL (dataset rpt_ranchos)
                         — lo ÚNICO que BI/Looker Studio debe consultar
    (mismos dominios que marts/)
  marts/exposures.yml     trazabilidad hasta el dashboard/reporte real
seeds/                    datos de referencia estáticos (CSV) (dataset seeds_ranchos)
macros/                   macros propias (incluye generate_schema_name.sql)
snapshots/                historización SCD tipo 2 de dimensiones que cambian (dataset int_ranchos)
tests/                    tests genéricos custom (además de los declarativos en cada .yml)
docs/dama_governance.md   reglas de gobernanza de datos del proyecto
docs/fase0_inspeccion.md  informe de inspección del proyecto (convenciones, modelo de datos, tiempo, replicación)
docs/fase2_arquitectura.md  decisiones de arquitectura de capas y datasets
```

Arquitectura completa: `ranchos` (L0 raw) → `stg_ranchos` (L1) →
`int_ranchos` (L2, solo snapshots) → `marts_ranchos` (L3) → `rpt_ranchos`
(L4, lo que consume BI) — ver `docs/fase2_arquitectura.md` para el
detalle de cada decisión.

## Setup local (primera vez)

```powershell
# 1. Clonar y entrar al proyecto
cd C:\ALBA_ANALYTICS\GANADERIA\dw_ranchos_app

# 2. Crear y activar el entorno virtual dedicado (no usar dbt global)
python -m venv .venv
.venv\Scripts\activate       # PowerShell: .venv\Scripts\Activate.ps1

# 3. Instalar dependencias fijadas
pip install -r requirements.txt

# 4. Instalar los packages de dbt (dbt_utils, dbt_expectations)
dbt deps

# 5. Autenticar contra GCP (una sola vez por máquina — NO es un service
#    account key, son credenciales OAuth locales de tu propia cuenta)
gcloud auth application-default login

# 6. Verificar que dbt puede conectarse
dbt debug
```

`profiles.yml` vive en `~/.dbt/profiles.yml` (fuera de este repo, por
convención estándar de dbt) y apunta al proyecto `alba-analytics-ganaderia`
vía `method: oauth` — nunca a un archivo de credenciales en texto plano.

## Comandos frecuentes

```powershell
dbt run                    # corre todos los modelos (target dev por defecto -> datasets dev_*)
dbt run --select staging   # solo la capa de staging
dbt test                   # corre todos los tests declarados en los .yml
dbt source freshness       # chequea que las tablas fuente reciban datos a tiempo
dbt docs generate && dbt docs serve   # catálogo de datos + grafo de lineage navegable
sqlfluff lint models/      # linting de estilo SQL (dialecto bigquery)
```

## VSCode

Abrí la carpeta `dw_ranchos_app` como workspace (no el repo `ranchos--app`
completo) para que la extensión de dbt/sqlfluff detecte `dbt_project.yml`
en la raíz. Extensiones recomendadas ya declaradas en
`.vscode/extensions.json` (VSCode las sugiere solas al abrir la carpeta):
`dbt Power User`, `SQLFluff`, `YAML`, `Cloud Code`.

## Entornos: dev vs. prod

El target `dev` (default) escribe en datasets con prefijo `dev_`
(`dev_staging`, `dev_marts`) — nunca sobre los datasets "reales" que algún
día consuma un dashboard. El target `prod` (`dbt run -t prod`, reservado
para cuando exista un pipeline/CI) escribe sin prefijo. Ver
`macros/generate_schema_name.sql`.

## Estado actual

El dataset `ranchos` (19 tablas `tb_dim_*`/`tb_fact_*`) ya existe en
`alba-analytics-ganaderia`, como réplica del dataset operacional real en
`ranchos-7c313` — migración histórica completa hecha vía `bq cp`
cross-project (2026-07-21), con actualización continua 3 veces al día
(8am/1pm/8pm hora de Panamá) vía Cloud Scheduler + Cloud Workflows +
BigQuery Data Transfer Service (2026-07-24). `dbt run`/`dbt test` ya
corren contra datos reales y actualizados. Detalle completo de la
arquitectura EL en `CLAUDE.md`, sección "Estado actual del proyecto".

## Pipeline EL (actualización de la réplica, 3x/día)

```
infra/workflows/trigger_el_transfer.yaml   Workflow que dispara el transfer
                                            (única lógica "propia" del pipeline)
```

Componentes en GCP (proyecto `alba-analytics-ganaderia`, todos en
`us-central1` salvo el transfer config que es `us`):
- Transfer config nativo `cross_region_copy` (Dataset Copy,
  `overwrite_destination_table: true`, schedule automático deshabilitado).
- Workflow `dw-trigger-el-transfer` — corre como
  `dw-transfer-runner@alba-analytics-ganaderia.iam.gserviceaccount.com`.
- Cloud Scheduler `dw-el-transfer-3x-diario` (cron `0 8,13,20 * * *`,
  `America/Panama`) — invoca el Workflow como
  `dw-scheduler-invoker@alba-analytics-ganaderia.iam.gserviceaccount.com`.

```powershell
# Redeploy del Workflow tras editar el .yaml
gcloud workflows deploy dw-trigger-el-transfer `
  --project=alba-analytics-ganaderia --location=us-central1 `
  --source=infra/workflows/trigger_el_transfer.yaml `
  --service-account=dw-transfer-runner@alba-analytics-ganaderia.iam.gserviceaccount.com

# Disparo manual de prueba (fuera de horario)
gcloud scheduler jobs run dw-el-transfer-3x-diario `
  --project=alba-analytics-ganaderia --location=us-central1

# Ver corridas recientes del transfer
bq ls --transfer_run --project_id=alba-analytics-ganaderia `
  "projects/702955643875/locations/us/transferConfigs/6a69a580-0000-2830-91fc-34c7e91a4873"
```
