# Fase 6 (técnicas) — Alarmas cuando el pipeline programado falla

**Fecha:** 2026-08-18
**Depende de:** `docs/fase_orquestacion_dbt.md` (el pipeline programado
que esta ronda alarma) — ese PR ya dejaba anotado explícitamente que
"hoy, un fallo del Job queda visible en Cloud Logging/Cloud Run Console,
pero nadie recibe una notificación activa". Esta ronda cierra eso.

## Alcance (confirmado con el usuario antes de implementar)

La Fase 6 del documento de especificación original tiene 2 mitades bien
distintas: alarmas **técnicas** (el pipeline en sí falló) y alarmas de
**negocio** (reverse ETL de alertas operativas hacia Firestore, ej.
preñeces atrasadas o insumo por agotarse). Confirmado vía
`AskUserQuestion` arrancar por la mitad técnica, autocontenida en este
repo — la de negocio queda para una ronda separada porque requiere
diseñar qué alertas exactas y tocar `ranchos--app`, con confirmación
explícita cuando se retome (ver "Prioridades actuales" en `CLAUDE.md`).
Canal de notificación: email (sobre Slack/webhook) — cero integración
nueva, alcanza con lo que ya provee Cloud Monitoring.

## Qué dispara la alarma

Dos condiciones, combinadas con `OR` en una sola alert policy (un solo
email sin importar cuál de las 2 piezas falló):

1. **El Workflow `dw-trigger-el-transfer` termina en `FAILED`** —
   métrica `workflows.googleapis.com/finished_execution_count`, label
   `status="FAILED"`.
2. **El Cloud Run Job `dw-dbt-build` termina en `result=failed`** —
   métrica `run.googleapis.com/job/completed_execution_count`, label
   `result="failed"`.

### Cambio necesario en el Workflow para que la condición 1 tenga sentido

Antes de esta ronda, `infra/workflows/trigger_el_transfer.yaml` devolvía
un resultado "exitoso" (`return`) incluso cuando el Dataset Copy no
terminaba en `SUCCEEDED` (o se agotaba el tiempo de polling) — el
detalle quedaba solo en el payload de retorno (`transfer_state`,
`dbt_run: "omitido - ..."`). Eso funcionaba bien como comportamiento
("no correr dbt contra una réplica desactualizada"), pero **las alarmas
de Cloud Monitoring se enganchan al ESTADO de la ejecución
(SUCCEEDED/FAILED), no inspeccionan el contenido del payload** — con el
`return`, una sync que nunca sincronizó hubiera quedado invisible para
la condición 1.

Fix: `transfer_no_exitoso`/`transfer_timeout` pasaron de `return` a
`raise` — la ejecución del Workflow ahora FALLA de verdad en esos 2
casos, con un mapa de error (`mensaje`/`estado_transfer` o
`mensaje`/`max_intentos`/`ultimo_estado_visto`) en vez de un string
concatenado (evita depender de si `string()` existe como función
built-in del lenguaje de expresiones de Workflows — no confirmado, no
vale la pena arriesgarse). Esto también es semánticamente más correcto:
un Workflow cuyo propósito era "sincronizar y compilar" que no llegó a
compilar no debería figurar como "exitoso" en su propio historial de
ejecuciones.

## Piezas nuevas

- **Canal de notificación** (`gcloud beta monitoring channels create
  --type=email`): `projects/alba-analytics-ganaderia/notificationChannels/11523500869606574724`,
  apunta a `josealba507@gmail.com`. Los canales de email NO requieren
  verificación antes de poder recibir notificaciones (a diferencia de
  SMS) — confirmado revisando el `describe` del canal, sin ningún campo
  de `verificationStatus` pendiente.
- **`infra/monitoring/alert_policy_pipeline_falla.json`** — la alert
  policy con las 2 condiciones de arriba, `combiner: OR`,
  `alertStrategy.autoClose: 86400s` (si no se cierra el incidente a
  mano, se autocierra al día). El campo `documentation` incluye los
  comandos `gcloud` exactos para diagnosticar cuál de las 2 piezas
  falló, directo en el cuerpo del email/incidente — no hace falta venir
  a este doc para saber el primer paso.
  Creada en GCP: `projects/alba-analytics-ganaderia/alertPolicies/10478512052705920944`.

## Verificación — falla forzada real, no solo config revisada

Mismo criterio que el resto de este proyecto: una alarma que "se ve
bien" en el JSON no es lo mismo que una alarma que dispara de verdad.
Se forzó una falla real del Cloud Run Job (`gcloud run jobs execute
dw-dbt-build --args=...`, override de argumentos solo para esa
ejecución puntual — la configuración guardada del Job no se tocó) y se
confirmó el incidente en Cloud Logging.

- **1er intento — reveló un hallazgo, no probó nada todavía:**
  `--args="dbt,run,--select,modelo_que_no_existe_para_forzar_falla"`.
  La ejecución terminó `succeededCount: 1` — **dbt NO trata un
  `--select` sin ningún match como error**, solo emite `WARNING: The
  selection criterion '...' does not match any enabled nodes` +
  `Nothing to do` y sale con código 0. Dato a tener en cuenta para
  cualquier futuro intento de "romper algo a propósito" en este
  proyecto — un selector que no matchea nada NO es una forma válida de
  forzar un fallo de dbt.
- **2do intento — falla real, confirmada de punta a punta:**
  `--args="false"` (el comando `false` de coreutils, siempre sale con
  código 1 — no depende de dbt en absoluto, prueba la infraestructura
  de alarma, no la lógica de dbt). Resultado:
  `gcloud run jobs executions describe` → `failedCount: 1`, razón
  `NonZeroExitCode`. ~5 min después, Cloud Logging registró el
  incidente real (`logName`
  `monitoring.googleapis.com%2FViolationOpenEventv1`):
  ```
  policy_display_name: "DW: el pipeline programado (sync EL + dbt build) fallo"
  policy_id: "10478512052705920944"
  terse_message: "Completed Executions for ... Cloud Run Job ... with
    metric labels {result=failed} is above the threshold of 0.000 with
    a value of 1.000."
  ```
  Esto confirma la cadena completa: falla real → métrica → condición de
  la alert policy → incidente abierto → notificación despachada al
  canal de email.
- **Confirmado por el usuario en su bandeja real** (`josealba507@gmail.com`,
  no solo evidencia de GCP): llegaron 2 correos — el de la falla (el
  `ViolationOpenEventv1` de arriba) **y uno de "exitoso"**. Ese segundo
  correo no viene de ninguna condición nueva — es la notificación de
  **auto-resolución** que Cloud Monitoring manda sola cuando el
  incidente se cierra porque la ejecución programada siguiente salió
  bien (`ViolationAutoResolveEventv1`, visto en el mismo rango de logs
  que el `ViolationOpenEventv1`). Comportamiento esperado del canal, no
  una alarma configurada aparte — vale la pena tenerlo presente para no
  confundirlo con una alarma de "todo OK" que no existe.

## Estado

Cierra la mitad técnica de la Fase 6, **verificado de punta a punta
incluida la entrega real del email** (no solo la evidencia de GCP). La
mitad de negocio (reverse ETL de alertas operativas hacia Firestore)
queda explícitamente fuera de esta entrega — ver "Prioridades actuales"
en `CLAUDE.md` para el alcance pendiente y la razón de separarla
(requiere diseño propio + tocar `ranchos--app`).
