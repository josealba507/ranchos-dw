# Orquestación: `dbt build` automático después de cada sync EL

**Fecha:** 2026-08-16
**Motivo:** el usuario preguntó cómo reparar los 3 falsos positivos
transitorios de reconciliación ya documentados en
`docs/fase5_reconciliacion_raw.md`/`docs/fase5_exactitud_insumos.md`
(`raw` levemente atrás de `ranchos-7c313` porque el test corría en un
momento arbitrario, no justo después de la sync). Esto también cierra el
ítem 6 de "Prioridades actuales" (automatizar `dbt run`/`test`/`snapshot`
en vez de correrlo siempre a mano) — son la misma tarea.

## Decisión de arquitectura (confirmada con el usuario antes de implementar)

Dos preguntas, ambas resueltas antes de tocar GCP:

1. **¿Aprobar la infraestructura nueva?** Sí — ninguna de las APIs
   (Cloud Run, Artifact Registry) estaba habilitada en
   `alba-analytics-ganaderia` hasta esta sesión.
2. **¿Cómo se actualiza la imagen del contenedor cuando cambian los
   modelos/tests?** Automático — Cloud Build trigger conectado a
   GitHub, reconstruye y redespliega en cada push a `main` (sobre la
   alternativa de un paso manual documentado).

## Cómo se resuelve la carrera

Antes: `dbt build` corría cuando yo lo lanzaba a mano, en un momento
arbitrario respecto a la sync 3x/día — si alguien capturaba un dato en
`ranchos--app` entre la última sync y mi corrida manual, `raw` quedaba
atrás y el test de reconciliación fallaba con un falso positivo
transitorio.

Ahora: el Workflow que dispara la sync (`infra/workflows/trigger_el_transfer.yaml`)
**espera a que la sync termine** (polling contra la API de BigQuery Data
Transfer) y **recién ahí** dispara `dbt build` — la ventana de carrera se
reduce a los segundos entre "la sync terminó" y "el próximo escritor real
de la app toca esos mismos datos", en vez de horas.

## Piezas nuevas

- **`infra/docker/Dockerfile`** — imagen del Cloud Run Job:
  `python:3.12-slim`, instala `requirements.txt`, corre `dbt deps` en
  build time (no en cada ejecución programada), copia el proyecto dbt +
  `infra/docker/dbt_profiles.yml` a `/root/.dbt/profiles.yml`. `CMD
  ["dbt", "build", "--target", "prod"]`.
- **`infra/docker/dbt_profiles.yml`** — SÍ se versiona (a diferencia de
  `~/.dbt/profiles.yml` del desarrollador): sin secretos, solo
  `method: oauth` + `project`/`dataset`/`location`. Dentro de Cloud Run,
  ADC resuelve las credenciales solas contra el service account adjunto
  al Job, sin key file. Nombrado `dbt_profiles.yml` (no `profiles.yml`
  a secas) — ver "Bug encontrado" más abajo.
- **`infra/docker/cloudbuild.yaml`** — build → push (Artifact Registry) →
  `gcloud run jobs update` (nueva revisión del Job). Variables
  `_AR_REPO`/`_REGION`/`_RUN_JOB` inyectadas por el trigger, no
  hardcodeadas.
- **`infra/workflows/trigger_el_transfer.yaml` (extendido)** — la misma
  lógica de siempre (disparar `startManualRuns`) más: polling cada 30s
  (tope 30 min) contra el estado del transfer run, y si `SUCCEEDED`,
  `POST .../jobs/dw-dbt-build:run`. Si `FAILED`/`CANCELLED`/timeout, NO
  dispara dbt — correrlo contra una réplica que sabemos desactualizada
  solo generaría más ruido.
- **`.dockerignore` / `.gcloudignore`** — nuevos, explícitos (ver "Bug
  encontrado" abajo para el porqué de `.gcloudignore`).

## Infraestructura GCP provisionada

- APIs habilitadas: `run.googleapis.com`, `artifactregistry.googleapis.com`,
  `cloudbuild.googleapis.com`, `secretmanager.googleapis.com` (esta
  última, necesaria recién al conectar GitHub — ver abajo).
- Artifact Registry: repo Docker `dw-images` (`us-central1`).
- Cloud Run Job `dw-dbt-build` (`us-central1`, 1 vCPU / 1Gi, timeout 30
  min, `max-retries=0` — un fallo debe ser visible, no reintentado a
  ciegas).
- **3 service accounts nuevos, cada uno con el permiso mínimo para su
  única función** (mismo criterio de roles acotados que ya usa
  `dw-transfer-runner`/`dw-scheduler-invoker` del EL original):
  - `dw-dbt-runner` — identidad del Job. `bigquery.dataEditor` +
    `bigquery.jobUser` en `alba-analytics-ganaderia`, y
    `bigquery.dataViewer` **cruzado a `ranchos-7c313`** (el source
    `ranchos_operacional` de la reconciliación lee esa fuente en vivo).
  - `dw-cloudbuild-deployer` — identidad del trigger de Cloud Build.
    `artifactregistry.writer` + `run.developer` + `logging.logWriter` +
    `iam.serviceAccountUser` sobre `dw-dbt-runner` (necesario para que
    `run.developer` pueda actualizar un Job que corre como otro SA).
  - `dw-transfer-runner` (ya existía) — sumó `logging.logWriter` (ver
    "Bug encontrado" abajo) y `roles/run.invoker` **acotado al Job
    `dw-dbt-build`** (no al proyecto completo) para poder invocar
    `:run`.

## Bugs encontrados y corregidos durante la implementación (los 4 en producción, no en un ambiente de prueba — no había forma de probar esto en `dev` local)

1. **`.gitignore` tiene un patrón `profiles.yml` sin `/` inicial**
   (para nunca commitear el `profiles.yml` LOCAL de un desarrollador) —
   ese patrón matchea en cualquier profundidad, así que también excluía
   `infra/docker/profiles.yml` del build context que sube `gcloud
   builds submit` (que por defecto hereda `.gitignore` como
   `.gcloudignore`). Síntoma: `COPY failed: file not found in build
   context`. Fix: renombrado a `dbt_profiles.yml` + `.gcloudignore`
   explícito (no depende de la herencia implícita de `.gitignore`).
2. **`gcloud builds submit --tag` exige el Dockerfile en la raíz del
   contexto** — no soporta un Dockerfile en subcarpeta con ese flag
   corto. Fix: usar `--config` con un `cloudbuild.yaml` que sí acepta
   `-f infra/docker/Dockerfile`.
3. **`sys.log` de GCP Workflows no acepta `json_payload` como
   argumento** (el nombre correcto es `json`) — error detectado recién
   al desplegar (`gcloud workflows deploy` valida la sintaxis
   server-side). Fix: `json:` en vez de `json_payload:`.
4. **La cuenta `dw-transfer-runner` no tenía `logging.logWriter`** —
   tenía un rol custom acotado (`bigquery.transfers.get/update`, el
   mismo rol `dwTransferRunner` documentado en `CLAUDE.md`, sección del
   pipeline EL) que nunca necesitó escribir logs hasta que este PR sumó
   el paso
   `log_status`. Sin este permiso, la ejecución del Workflow fallaba
   con 403 en el primer `sys.log`, ANTES de llegar siquiera a disparar
   dbt — detectado en la primera corrida end-to-end real. Fix: sumado
   el rol al proyecto.
5. **Conectar Cloud Build a GitHub por primera vez en este proyecto
   necesitó 2 permisos previos no obvios**: habilitar
   `secretmanager.googleapis.com` (el flujo de conexión guarda el token
   de OAuth ahí) y otorgarle `roles/secretmanager.admin` al service
   agent de Cloud Build (`service-<PROJECT_NUMBER>@gcp-sa-cloudbuild.iam.gserviceaccount.com`)
   — recién creado con la habilitación de la API, sin ese rol asignado
   por defecto. Sin ambos, `gcloud builds connections create github`
   fallaba con `PERMISSION_DENIED` sobre Secret Manager, antes incluso
   de llegar al paso de autorización en el navegador.

## Verificación end-to-end (contra producción real, no hay forma de simular esto en local/dev)

- Job ejecutado manualmente una vez (imagen `bootstrap`): `dbt build
  --target prod` completo, `PASS=458 WARN=0 ERROR=0 TOTAL=458`, ~13 min.
  Primera vez que el target `prod` corre de verdad — confirmado con `bq
  ls` que los 5 datasets sin prefijo (`stg_ranchos`/`int_ranchos`/
  `marts_ranchos`/`rpt_ranchos`/`metadata_ranchos`) se crearon.
- Workflow completo ejecutado 2 veces de punta a punta:
  - 1ª corrida: falló en `log_status` por el bug 4 de arriba (403,
    faltaba `logging.logWriter`) — corregido y redesplegado.
  - 2ª corrida: `state: SUCCEEDED`, `transfer_state: SUCCEEDED`, disparó
    el Job (`dw-dbt-build-n97qb`), que a su vez completó
    `PASS=458 ERROR=0` — **0 discrepancias de reconciliación esta vez**
    (confirma empíricamente que el problema era transitorio: sin
    escrituras nuevas en el momento exacto de la sync, no hay drift que
    reportar).
- Trigger de Cloud Build (`dw-dbt-image-on-push-main`) probado
  manualmente contra la rama de feature antes de mergear (ver PR) —
  confirma que el pipeline build→push→deploy funciona antes de
  depender de un push real a `main`.

## Estado

Cierra el ítem 6 de "Prioridades actuales" (automatizar `dbt
run`/`test`/`snapshot`) y resuelve de raíz el falso positivo transitorio
de reconciliación (`docs/fase5_reconciliacion_raw.md`,
`docs/fase5_exactitud_insumos.md`) — el próximo disparo real de Cloud
Scheduler (8am/1pm/8pm hora de Panamá) ya usa este flujo completo, sin
ningún paso manual.

**No incluido en este PR, a propósito:** alertas cuando el `dbt build`
programado falla (Fase 6, ya documentada como trabajo separado — "canal
técnico" vs. "canal de negocio"). Hoy, un fallo del Job queda visible en
Cloud Logging/Cloud Run Console, pero nadie recibe una notificación
activa. Igual criterio que Elementary: la infraestructura de detección
ya corre sola, falta la capa de notificación encima.
