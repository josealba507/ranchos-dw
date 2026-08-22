# Setup local y operación

Contenido movido desde `README.md` (Fase 2 del plan de portfolio) — el
README ahora es la puerta de entrada para alguien externo evaluando el
proyecto en 2 minutos; este documento es la referencia operativa para
trabajar en el repo día a día, igual que el resto de `docs/`.

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
cd <ruta-local-del-repo>

# 2. Crear y activar el entorno virtual dedicado (no usar dbt global)
python -m venv .venv
.venv\Scripts\activate       # PowerShell: .venv\Scripts\Activate.ps1

# 3. Instalar dependencias fijadas
pip install -r requirements.txt

# 4. Instalar los packages de dbt (dbt_utils, dbt_expectations, elementary)
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
dbt build                  # run + test + snapshot en orden de dependencias (target dev por defecto -> datasets dev_*)
dbt run --select staging   # solo la capa de staging
dbt test                   # corre todos los tests declarados en los .yml
dbt source freshness       # chequea que las tablas fuente reciban datos a tiempo
dbt docs generate && dbt docs serve   # catálogo de datos + grafo de lineage navegable
sqlfluff lint models/      # linting de estilo SQL (dialecto bigquery)
```

**`sqlfluff lint` es un chequeo local/pre-commit, no corre en CI.** El
templater de dbt que usa (`templater = dbt` en `.sqlfluff`) necesita una
conexión real a BigQuery para `set_relations_cache` — a diferencia de
`dbt parse`, que compila el proyecto entero (Jinja, refs, sources,
macros) sin tocar el warehouse. Como este repo es público, no hay un
service account guardado como secret solo para poder lintear en CI — se
corre a mano antes de cada PR. Ver `.github/workflows/ci.yml` para el
detalle completo de esta decisión.

## Catálogo de datos (dbt docs), publicado en GitHub Pages

El catálogo completo (columnas, descripciones, tests) y el grafo de
lineage navegable están publicados en
**https://josealba507.github.io/ranchos-dw/** — generados con
`dbt docs generate` y publicados manualmente en la rama `gh-pages`
(camino simple primero, sin automatizar todavía).

Para regenerar y republicar después de un cambio de modelos:

```powershell
# 1. Generar el sitio contra dev (necesita conexión real a BigQuery,
#    a diferencia de dbt parse — mismo motivo por el que esto no corre
#    en CI, ver más arriba)
dbt docs generate --target dev

# 2. Publicar en un worktree aislado de la rama gh-pages, sin tocar el
#    working tree de main
git worktree add /tmp/ranchos-dw-ghpages gh-pages
cp target/index.html target/manifest.json target/catalog.json target/run_results.json /tmp/ranchos-dw-ghpages/
cd /tmp/ranchos-dw-ghpages
git add -A && git commit -m "Actualizar dbt docs"
git push origin gh-pages
cd -
git worktree remove /tmp/ranchos-dw-ghpages
```

`gh-pages` es una rama huérfana (`git worktree add --orphan -b gh-pages`,
así se creó la primera vez) que solo contiene el sitio estático — nunca
se mergea a `main`, ni al revés. GitHub Pages ya está configurado para
servir esa rama desde la raíz (detectado solo al pushear la rama por
primera vez, sin necesitar configuración manual en la UI).

**Mejora futura, no implementada ahora a propósito:** automatizar este
paso dentro del Cloud Build existente (`infra/docker/cloudbuild.yaml`,
ver `docs/fase_orquestacion_dbt.md`) — que cada push a `main` regenere y
republique el catálogo solo, en vez de un paso manual. Se dejó fuera de
esta ronda para no acoplar la publicación de documentación (best-effort,
no crítica) al pipeline de producción (dbt build 3x/día, sí crítico).

## VSCode

Abrí la carpeta `dw_ranchos_app` como workspace (no el repo `ranchos--app`
completo) para que la extensión de dbt/sqlfluff detecte `dbt_project.yml`
en la raíz. Extensiones recomendadas ya declaradas en
`.vscode/extensions.json` (VSCode las sugiere solas al abrir la carpeta):
`dbt Power User`, `SQLFluff`, `YAML`, `Cloud Code`.

## Entornos: dev vs. prod

El target `dev` (default) escribe en datasets con prefijo `dev_`
(`dev_stg_ranchos`, `dev_marts_ranchos`) — nunca sobre los datasets
"reales" que consumen los reportes/pipelines. El target `prod`
(`dbt build -t prod`) escribe sin prefijo, y es el que realmente corre
3 veces al día dentro del Cloud Run Job programado (ver
"Pipeline EL + orquestación" abajo) — ya no es un target reservado para
el futuro, está en uso activo. Ver `macros/generate_schema_name.sql`.

## Estado de los datos

El dataset `ranchos` (26 tablas `tb_dim_*`/`tb_fact_*`) existe en
`alba-analytics-ganaderia`, como réplica del dataset operacional real —
migración histórica completa hecha vía `bq cp` cross-project, con
actualización continua 3 veces al día (8am/1pm/8pm hora de Panamá) vía
Cloud Scheduler + Cloud Workflows + BigQuery Data Transfer Service.
`dbt run`/`dbt test` corren contra datos reales y actualizados. Detalle
completo en `CLAUDE.md`, sección "Estado actual del proyecto".

## Pipeline EL + orquestación (actualización de la réplica, 3x/día)

```
infra/workflows/trigger_el_transfer.yaml   Workflow: dispara la sync, espera a que
                                            termine, y si terminó bien dispara el
                                            Cloud Run Job de dbt build --target prod
infra/docker/                              Dockerfile + cloudbuild.yaml del Cloud
                                            Run Job — imagen reconstruida sola en
                                            cada push a main
infra/monitoring/                          Alert policy: email si el Workflow o el
                                            Cloud Run Job programado fallan
```

Ver [`docs/fase_orquestacion_dbt.md`](fase_orquestacion_dbt.md) y
[`docs/fase6_alarmas_tecnicas.md`](fase6_alarmas_tecnicas.md) para el
detalle completo (incluidos los bugs reales encontrados armando esto).

```powershell
# Redeploy del Workflow tras editar el .yaml
gcloud workflows deploy dw-trigger-el-transfer `
  --project=alba-analytics-ganaderia --location=us-central1 `
  --source=infra/workflows/trigger_el_transfer.yaml `
  --service-account=dw-transfer-runner@alba-analytics-ganaderia.iam.gserviceaccount.com

# Disparo manual de prueba (fuera de horario)
gcloud workflows execute dw-trigger-el-transfer `
  --project=alba-analytics-ganaderia --location=us-central1
```
