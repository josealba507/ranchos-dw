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
  staging/<fuente>/     stg_*  — 1:1 con la tabla fuente, vista
  intermediate/          int_*  — joins/agregaciones reutilizables, ephemeral
  marts/<dominio>/       dim_*/fct_* — modelos finales, tabla, lo único que BI consulta
    finanzas/
    leche/
    hato/
    veterinaria/
  marts/exposures.yml     trazabilidad hasta el dashboard/reporte real
seeds/                    datos de referencia estáticos (CSV)
macros/                   macros propias (incluye generate_schema_name.sql)
snapshots/                SCD tipo 2 si algún día hace falta sobre una dim
tests/                    tests genéricos custom (además de los declarativos en cada .yml)
docs/dama_governance.md   reglas de gobernanza de datos del proyecto
```

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
cross-project (2026-07-21). `dbt run`/`dbt test` ya corren contra datos
reales. Pendiente: decidir e implementar cómo esa réplica se mantiene
actualizada hacia adelante (ver `CLAUDE.md`, sección "Estado actual del
proyecto").
