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

### Resultado real en producción

Medido en `dw-dbt-build-n5f8m` (2026-08-24 03:27 UTC), la primera corrida
después del deploy, disparada con el Workflow completo (sync EL + build)
para que fuera fiel al flujo de las 3x/día:

| | antes | después | mejora |
|---|---|---|---|
| Hook `on-run-end` | 1439.29s (~24 min) | **283.04s (4.7 min)** | **5.1x** |
| Runtime del build | 1947.12s (~32.5 min) | **649.62s (10.8 min)** | 3.0x |
| Job completo | 34m17s / 35m08s | **13m13s** | 2.6x |
| Resumen dbt | `PASS=459 WARN=2 ERROR=0` | `PASS=447 WARN=0 ERROR=0` | — |
| Filas nuevas en `test_result_rows` por corrida | ~43.500 | **2.520** | **17x** |

La mejora real (5.1x en el hook) superó la proyección de ≈2.7x porque la
estimación solo contemplaba la reducción de alcance (columnas × buckets),
sin contar que menos filas por lote también significa muchas menos
sentencias `INSERT` de 250 KB — y el costo dominante era el overhead de
submit/poll de cada una, no el volumen de datos en sí.

Los 2 warnings que arrastraba (`elementary_source_all_columns_anomalies`
sobre composición y transacciones financieras) desaparecieron: eran
anomalías detectadas sobre métricas con el bucketing roto.

**Prueba de que el bucketing quedó corregido en producción**, no solo en
dev: antes de esa corrida `data_monitoring_metrics` tenía 2.901 filas con
bucket diario y 0 con bucket por corrida (después de la purga descrita
abajo); después quedó en 5.697 diarias y **sigue en 0 por corrida** — las
2.796 métricas nuevas se escribieron todas con bucket diario.

El costo ahora está atado a los **días** (`days_back: 14`), no a la
cantidad de corridas: se estabiliza solo en vez de crecer ~3 buckets/día
indefinidamente.

### Purga de los datos acumulados por la mala configuración

Confirmada explícitamente con el usuario antes de ejecutar (criterio ya
establecido en el proyecto para cualquier operación destructiva sobre
producción, ver el incidente del `DROP TABLE` en el CLAUDE.md de
`ranchos--app`). Alcance exacto, ejecutado el 2026-08-24 ~02:35 UTC:

1. `TRUNCATE TABLE metadata_ranchos.test_result_rows` — 595.198 filas /
   749 MB, todas `anomaly_detection`. `TRUNCATE` y no `DROP` a propósito:
   preserva el esquema para que Elementary siga escribiendo sin recrear
   la tabla.
2. `DELETE FROM metadata_ranchos.data_monitoring_metrics WHERE bucket_end
   != TIMESTAMP_TRUNC(bucket_end, DAY)` — 44.712 filas. **Esto no era
   limpieza cosmética:** esas filas son el set de entrenamiento que
   Elementary lee, y mezcladas con los buckets diarios nuevos habrían
   corrompido las líneas base de anomalías durante ~14 días. El predicado
   deja intactas las 2.901 filas correctas de volume/freshness.

Se conservaron `elementary_test_results` (54.079 filas) y
`dbt_run_results` (12.353) — la serie histórica de calidad que la Fase 5
pidió explícitamente mantener (ver `docs/fase5_reconciliacion_raw.md`).

**Dos lecciones del proceso, ambas por verificar antes de borrar:**

- **Había una corrida de producción en vuelo.** `dw-dbt-build-zgglf`
  (la programada de las 8pm de Panamá) arrancó 01:02 UTC y todavía
  estaba corriendo. Borrar en ese momento habría chocado con el `INSERT`
  de su hook y con el rate limit de DML por tabla que ya mordió varias
  veces a este proyecto. Se esperó a que terminara (01:37 UTC, exitosa) —
  y de paso agregó 43.546 filas más a `test_result_rows` (551.652 →
  595.198), justamente porque corría todavía con el código viejo.
- **Las 157 tablas `__tmp_` de `metadata_ranchos` NO eran basura.** A
  primera vista parecían restos sin limpiar, pero todas tenían fecha del
  día: eran el estado en vuelo de esa misma corrida. Elementary las
  limpia sola al terminar (`clean_elementary_temp_tables`, verificado:
  quedaron en 0 después). Borrarlas a mano habría roto el job en curso.

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

Cerrado. Las 3 causas raíz corregidas y verificadas end-to-end contra el
flujo real de producción (Workflow → sync → build), sin errores:
`PASS=447 WARN=0 ERROR=0` en 13m13s, contra 34-35 min antes.

El timeout del Job queda en 3600s. Ya no es un margen ajustado como lo era
cuando se subió: con el hook en ~4.7 min y el build total en ~11 min, hay
~5x de holgura, y el costo ya no crece con la frecuencia de corridas.

Queda como mejora futura, no bloqueante: el pipeline sigue escribiendo
artefactos de Elementary (`test_result_rows`, `dbt_run_results`) que hoy
no consume nadie, porque `elementary-data` (el CLI `edr` que genera el
reporte) no está instalado. Se pueden apagar con
`disable_tests_results`/`disable_run_results` si nunca se va a usar ese
reporte, o dejarlos como están si en algún momento se quiere levantarlo —
ahora que el volumen es 17x menor, ya no es un costo relevante.
