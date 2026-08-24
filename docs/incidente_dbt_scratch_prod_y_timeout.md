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

## Causa raíz 3 — el hook de Elementary: `all_columns_anomalies` sin `timestamp_column`

Investigado después de cerrar las 2 causas de arriba, porque el hook
`on-run-end` se estaba comiendo más de dos tercios del build (~24 min de
~33) y venía creciendo.

**El defecto:** en `_ranchos__sources.yml`, las 26 tablas declaraban 3
tests de Elementary. `volume_anomalies` y `freshness_anomalies` pasaban
`timestamp_column`; **`all_columns_anomalies` no**. Sin esa columna,
Elementary no puede agrupar las métricas por fecha del dato y usa cada
EJECUCIÓN del test como su propio bucket de la serie temporal — la serie
crece con la cantidad de corridas (3/día), no con los días.

**Evidencia (no inferido — medido en `data_monitoring_metrics`):**

| métrica | test de origen | buckets observados |
|---|---|---|
| `row_count`, `freshness` | los que **sí** pasaban `timestamp_column` | `2026-08-23 00:00:00` → diarios |
| `null_count`, `null_percent`, `missing_count`, `average_length`… | `all_columns_anomalies` | `2026-08-23 21:49:56` → uno por corrida |

26 buckets distintos en 8 días ≈ 3.25/día = exactamente la frecuencia del
pipeline. Y como cada test de anomalías devuelve su serie completa
evaluada como "result rows" que se persisten, las filas por test crecieron
linealmente: `1.6 → 3.2 → 6.2 → 9.1 → 12.0 → 15.4 → 18.8 → 22.7`
(~+3/día = la cantidad de corridas, no de días).

**Cómo eso se convierte en 24 minutos:** esas filas se insertan con
`INSERT ... VALUES` troceados a `query_max_size` = 250 KB (override
específico de BigQuery dentro de Elementary). Medido sobre la ejecución
`dw-dbt-build-92kvp`: **267 jobs de INSERT, 244 KB promedio, 66.4 MB de
texto SQL, secuenciales** — 614s de los 720s de tiempo de query del hook.
En total 677 jobs de BigQuery en la ventana, pero solo ~1295s de
slot-time: es overhead de submit/poll sobre cientos de sentencias chicas,
no cómputo.

**Agravante:** `metadata_ranchos.test_result_rows` acumuló **749 MB /
551.652 filas**, todas de `anomaly_detection`. Esa tabla existe para el
reporte UI de Elementary — pero `elementary-data` (el CLI `edr`) no está
en `requirements.txt` y ningún modelo del proyecto lee ninguna tabla de
Elementary. El grueso de ese costo alimentaba algo que nadie consume.

**Hacia dónde iba:** `days_back: 14` × 3 corridas/día ≈ 42 buckets en la
meseta, contra 26 medidos al día 8 (~62%). Proyección: hook ~38-40 min,
build total ~48-50 min — el timeout nuevo de 60 min tenía bastante menos
margen del que aparentaba, y se erosionaba con cada columna agregada.

### Fix aplicado (2 partes)

1. **`timestamp_column` en `all_columns_anomalies`**, con la columna
   TIMESTAMP real de cada tabla (`timestamp_registro`, o
   `timestamp_evento` en `tb_fact_logs_actividad` — verificadas contra
   `INFORMATION_SCHEMA`, ambas TIMESTAMP nativas, sin cast).
2. **El test sale de las 14 tablas DIM.** Son catálogos chicos que se
   editan in-place, no acumulan filas por fecha: no hay serie temporal de
   columnas que analizar, solo generaban costo. `volume_anomalies` y
   `freshness_anomalies` siguen aplicando en las 26.

**Verificación (corrida real contra `dev`, no solo parseo):** los 64
tests de Elementary corrieron `PASS=66 ERROR=0`, y los buckets de
`null_count`/`null_percent`/`average_length` pasaron de la hora exacta de
cada corrida a **medianoche diaria** (`2026-08-24 00:00:00`), igual que
`row_count` — que es exactamente la prueba de que el bucketing se
corrigió. Quedan topados en 13-14 buckets por `days_back`, ya
desacoplados de la frecuencia del pipeline.

**Reducción medida en alcance:** de 278 columnas monitoreadas (90 dim +
188 fact) a 188; y de ~26 buckets (rumbo a 42) a ~14 fijos. ≈2.7x menos
trabajo de inmediato, ≈4.4x contra la meseta a la que iba — y, más
importante que el número, **deja de crecer con la cantidad de corridas.**
El número real en producción sale de la primera corrida programada
después del deploy.

**Pendiente, requiere decisión explícita:** `test_result_rows` conserva
las 749 MB acumuladas por la mala configuración. Son datos históricos de
una serie que ya no es comparable con la nueva (bucketing distinto) y que
nada consume, pero **borrarlos es una operación destructiva sobre
producción** — no se hace sin confirmación explícita (ver
`docs/fase6_alarmas_tecnicas.md` y el criterio ya establecido en el
proyecto para DROP/TRUNCATE en prod).

## Barrida de tablas nuevas — `scripts/detectar_tablas_nuevas.py`

Salió de la misma sesión: la réplica EL copia el dataset completo, así que
una tabla nueva de RanchOS aparece sola en `ranchos`, pero declararla como
source es un paso manual — hasta que alguien lo haga, esa tabla vive en el
warehouse sin ningún test de calidad, sin freshness y sin reconciliación.

El script compara el dataset raw contra `_ranchos__sources.yml` y reporta
las dos direcciones (tablas sin declarar, y sources que apuntan a algo que
ya no existe). Para cada tabla nueva emite el bloque YAML sugerido, con la
columna de tiempo verificada contra `INFORMATION_SCHEMA` y respetando la
regla de arriba (`all_columns_anomalies` solo en fact, siempre con
`timestamp_column`).

Solo lee — nunca modifica el YAML ni BigQuery: qué monitorear sigue siendo
una decisión explícita. **No corre dentro del pipeline programado a
propósito:** el pipeline debe fallar por problemas de datos, no por una
tabla nueva que todavía nadie tuvo tiempo de modelar.

Estado real al crearlo: 30 objetos en el dataset, 26 declarados — los 4
faltantes son `VS_*`, todas `VIEW` legacy pre-dbt de julio, que el script
ignora por defecto. **Las 26 tablas reales están 100% cubiertas.**
Verificado además con un control negativo (sacar 2 tablas del YAML y
confirmar que las detecta, con el bloque sugerido byte-idéntico al real).

## Estado

`dw-dbt-build` verificado end-to-end contra el flujo real de producción
(Workflow → sync → build), sin errores. Las 3 causas raíz corregidas.
