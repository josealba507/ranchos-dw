# Incidente — `dw-dbt-build` fallando en cada corrida programada

**Fecha:** 2026-08-23
**Disparador:** alerta real de Cloud Monitoring (la alert policy de
`docs/fase6_alarmas_tecnicas.md`, no una prueba forzada) — email real a
`josealba507@gmail.com` avisando que el Cloud Run Job `dw-dbt-build`
había terminado con `result: failed`.

## Diagnóstico — seguir el runbook, no asumir

Primer paso: el propio `documentation` de la alert policy
(`infra/monitoring/alert_policy_pipeline_falla.json`) trae los comandos
exactos para diagnosticar. Al usarlos en vivo apareció el primer hallazgo
de este incidente:

- **El comando documentado tenía un bug real:**
  `gcloud workflows executions list --workflow=dw-trigger-el-transfer ...`
  falla con `unrecognized arguments` — `WORKFLOW` es un argumento
  posicional, no una flag (`gcloud workflows executions list --help`
  lo confirma: `gcloud workflows executions list (WORKFLOW :
  --location=LOCATION)`). Nunca se había ejecutado ese comando exacto
  hasta este incidente real — quedó sin probar desde que se escribió en
  `docs/fase6_alarmas_tecnicas.md`. Corregido acá mismo (ver "Qué se
  corrigió" abajo), incluyendo el `documentation` de la policy en GCP,
  no solo el archivo versionado.

Con la sintaxis correcta: las últimas 5 ejecuciones del Workflow
`dw-trigger-el-transfer` estaban `SUCCEEDED` — la sincronización EL
(BigQuery Data Transfer) nunca fue el problema. Las últimas 5 ejecuciones
del Cloud Run Job `dw-dbt-build`, en cambio, habían fallado todas, en 2
patrones distintos (confirmados leyendo `gcloud logging read` sobre cada
una, no supuestos):

1. Timeout — la ejecución se cortaba a los 1800s (30 min) sin terminar.
2. `exit code 1` — el proceso sí terminaba, pero dbt reportaba un error.

## Causa raíz 1 — faltaba `dbt_scratch` para el target `prod`

Los 2 unit tests nativos agregados sobre
`int_movimientos_insumos_con_insumo_historico`
(`models/intermediate/_intermediate__models.yml`, ver ese archivo)
necesitan un dataset "scratch" en BigQuery donde dbt materializa las
filas sintéticas de `given`/`expect` antes de compararlas. Al
implementarlos se creó y verificó **`dev_dbt_scratch`** (el prefijo del
target `dev`, el único contra el que se corrió localmente) — pero nunca
se creó el equivalente sin prefijo, **`dbt_scratch`**, que es el que
usa el target `prod` real (`macros/generate_schema_name.sql`). Cada
corrida programada 3x/día desde que esos unit tests se mergearon venía
fallando ese paso con `Dataset alba-analytics-ganaderia:dbt_scratch was
not found`.

**Por qué no se detectó antes:** la verificación de esos unit tests fue
100% contra `dev` (ver el propio archivo de tests y su historial) — el
mismo tipo de brecha "verificado en dev, nunca corrido contra prod
real" que ya había aparecido antes en este proyecto de otras formas.
Ningún paso de esa sesión corrió `dbt build --target prod` de verdad
antes de mergear.

**Fix:**

```powershell
bq mk --dataset --location=US alba-analytics-ganaderia:dbt_scratch
```

## Causa raíz 2 — el timeout del Job quedó corto para el runtime real actual

El hook `on-run-end` de Elementary (detección de anomalías, corre al
final de cada `dbt build`) viene tardando **~20-24 minutos por sí solo**
— confirmado en las 2 corridas de verificación de este incidente
(1355.15s y 1439.29s). Sumado al resto del build (~9-10 min), el
runtime total real hoy es de **~31-33 minutos**, por encima del timeout
de 1800s (30 min) que tenía el Cloud Run Job desde que se configuró en
`docs/fase_orquestacion_dbt.md` — ese valor nunca se revisó contra el
runtime real a medida que el pipeline creció (más modelos, más tests,
más datos).

**Fix:**

```powershell
gcloud run jobs update dw-dbt-build `
  --region=us-central1 --project=alba-analytics-ganaderia `
  --task-timeout=3600
```

## Verificación — 2 corridas reales, la primera reveló algo más

**Corrida 1 (`dw-dbt-build-dnxjp`, ejecución directa del Job vía
`gcloud run jobs execute`):** confirmó los 2 fixes de arriba — los 2
unit tests pasaron limpio (sin error de dataset) y el hook de Elementary
corrió dentro del nuevo límite (1865.83s de runtime total, contra
3600s) — pero la ejecución igual terminó en `exit code 1`, por un motivo
**distinto y no relacionado a los 2 fixes:**

```
[ERROR]: in test source_reconciliacion_conteo_raw_vs_operacional_..._tb_fact_logs_actividad_...
  Got 1 result, configured to fail if != 0
```

Causa: ejecutar el Job directamente se salta el paso de sincronización
(`dw-trigger-el-transfer`, que en producción real siempre corre
inmediatamente antes) — `raw` quedó un par de filas atrás de la fuente
operacional real (698 vs. 700 en `tb_fact_logs_actividad`, confirmado
con una query directa) simplemente porque hubo actividad real en el
sistema entre la última sync programada y este intento manual. Este es
exactamente el "falso positivo transitorio" que el propio
`tests/generic/test_reconciliacion_conteo_raw_vs_operacional.sql` ya
documenta en su comentario de cabecera como comportamiento esperado —
no un bug nuevo, y no algo que este incidente haya causado.

**Corrida 2 (`58cce686-...`, Workflow `dw-trigger-el-transfer`
completo — sync real + dbt build, réplica exacta del flujo de
producción):**

```
Done. PASS=459 WARN=2 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=461
Container called exit(0).
```

Runtime total: 1947.12s (~32.5 min, hook de Elementary: 1439.29s),
Job completo en 34m17s — dentro del nuevo límite de 3600s. Los 2
warnings restantes (`elementary_source_all_columns_anomalies` sobre
composición/transacciones financieras) son detección de anomalías
normal de Elementary, no relacionados a este incidente.

## Qué se corrigió en este PR

- `bq mk` del dataset `dbt_scratch` (ya aplicado en GCP antes de este
  PR — no versionado, es infraestructura de datos, no código).
- `gcloud run jobs update` del timeout (ídem, ya aplicado en GCP).
- `infra/monitoring/alert_policy_pipeline_falla.json`: comando `gcloud
  workflows executions list` corregido a su forma posicional correcta,
  más un 3er paso en el runbook apuntando directo a este doc si el
  patrón de error es el de la Causa raíz 1 — aplicado tanto en el
  archivo versionado como en la alert policy real en GCP (`gcloud alpha
  monitoring policies update ... --policy-from-file=...`), para que el
  runbook que de verdad se lee desde el email/incidente ya tenga el
  comando correcto la próxima vez.

## Estado

`dw-dbt-build` verificado end-to-end contra el flujo real de producción
(Workflow → sync → build), sin errores. Pendiente, no iniciado — el
runtime del hook de Elementary (~20-24 min) viene creciendo y hoy usa
más de dos tercios del tiempo total del build; vale la pena
investigarlo si sigue subiendo, antes de que vuelva a comerse el nuevo
timeout de 60 min.
