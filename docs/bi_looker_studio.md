# Acceso de BI (Looker Studio) — solo la capa L4

**Fecha:** 2026-08-30
**Estado:** comandos preparados, **todavía no ejecutados en GCP**. Este
documento es la referencia para ejecutarlos y para verificar después que
el permiso quedó realmente acotado.

Implementa en infraestructura la regla que `docs/dama_governance.md`
sección 5 declara en prosa: *BI se conecta solo al dataset `rpt_ranchos`
(L4), nunca a `marts_ranchos` (L3), `stg_ranchos` ni a las tablas fuente
crudas*. Hasta ahora esa regla era una convención — nada impedía apuntar
un dashboard a L3. Con esto pasa a ser una frontera técnica.

## Qué expone L4 hoy

16 vistas en `rpt_ranchos`, agrupadas por dominio:

| Dominio | Vistas |
|---|---|
| Leche | `rpt_metrica_entrega_leche`, `rpt_entregas_leche_recientes`, `rpt_calidad_leche_reciente` |
| Veterinaria | `rpt_metrica_estado_reproductivo`, `rpt_metrica_transicion_palpamiento`, `rpt_vacas_a_palpar`, `rpt_palpamientos_recientes`, `rpt_tratamientos_recientes`, `rpt_pesaje_resumen_diario` |
| Finanzas | `rpt_metrica_finanzas_mensual`, `rpt_transacciones_financieras_recientes` |
| Insumos | `rpt_metrica_existencia_insumo`, `rpt_movimientos_insumo_recientes` |
| Hato | `rpt_animales_activos`, `rpt_nacimientos_recientes`, `rpt_salidas_recientes` |

Las 6 `rpt_metrica_*` son la capa de métricas con grano declarado; el
resto son las vistas de detalle que ya existían.

## Por qué la conexión nunca apunta a `marts_ranchos`

No es purismo arquitectónico: son tres consecuencias concretas.

1. **Permite refactorizar sin romper dashboards.** L3 es el motor técnico
   del esquema estrella. Si un dashboard consulta `fct_venta_leche`
   directo, renombrar una columna de ese hecho rompe el reporte de alguien
   más. L4 es el contrato estable que absorbe esos cambios.
2. **Da acceso de reporting sin dar acceso a los datos crudos.** En
   BigQuery los permisos se otorgan por dataset — por eso hay un dataset
   por capa. Conceder L4 no concede las 26 tablas fuente ni el histórico
   completo con datos versionados.
3. **Evita que cada consumidor calcule distinto.** Si el dashboard define
   "resultado neto" con un campo calculado propio y el servidor MCP lo
   define en su código, tarde o temprano dan números distintos para la
   misma pregunta. La definición vive una sola vez, en dbt.

## Hallazgo: las vistas autorizadas no son opcionales

**Verificado el 2026-08-30: `marts_ranchos` no tiene ninguna vista ni
dataset autorizado configurado** — su lista de `access` solo trae los ACL
por defecto del proyecto más `dw-dbt-runner` como OWNER.

Esto importa porque en BigQuery **una vista normal se ejecuta con los
permisos de quien la consulta**, no con los del dueño de la vista. Es
decir: dar `dataViewer` sobre `rpt_ranchos` y nada más NO alcanza — cada
consulta fallaría con *permission denied* sobre `marts_ranchos`, que es de
donde las vistas leen.

Sin resolver esto, la regla de gobierno es inimplementable: habría que
darle a BI acceso a L3 (rompiendo la regla) o los dashboards no
funcionarían.

La solución es autorizar el **dataset** `rpt_ranchos` sobre
`marts_ranchos`. Se elige dataset autorizado y no vista por vista porque
cada modelo nuevo en L4 queda cubierto solo, sin un paso manual que
alguien vaya a olvidar — exactamente el tipo de paso manual que ya causó
un incidente en este proyecto (ver
`docs/incidente_dbt_scratch_prod_y_timeout.md`, causa raíz 1).

**Verificado que alcanza con autorizar un solo dataset:** las 16 vistas de
L4 dependen únicamente de `marts_ranchos` (13 modelos referenciados, todos
`dim_*`/`fct_*`). Ninguna lee de staging, intermediate ni snapshots.

## Los comandos

Ejecutar en orden. Ninguno es destructivo: crean una identidad nueva y
agregan permisos, sin quitar ni modificar los existentes.

### 1. Crear la service account

```bash
gcloud iam service-accounts create bi-looker-reader \
  --project=alba-analytics-ganaderia \
  --display-name="BI: Looker Studio lee solo rpt_ranchos (L4)"
```

Identidad dedicada, siguiendo la convención de las 4 que ya existen
(`dw-dbt-runner`, `dw-transfer-runner`, `dw-cloudbuild-deployer`,
`dw-scheduler-invoker`): una service account por función, con el permiso
mínimo de esa función. Si mañana hay que revocar el acceso de BI, se borra
esta y nada más se ve afectado.

### 2. Permiso para ejecutar consultas (nivel proyecto)

```bash
gcloud projects add-iam-policy-binding alba-analytics-ganaderia \
  --member="serviceAccount:bi-looker-reader@alba-analytics-ganaderia.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"
```

**Por qué a nivel proyecto y no dataset:** BigQuery separa *leer datos* de
*ejecutar un job*. Leer una tabla necesita `bigquery.tables.getData`, que
sí se otorga por dataset; pero ejecutar una consulta necesita
`bigquery.jobs.create`, y los jobs son un recurso **de proyecto** — no
existe forma de acotarlos a un dataset.

Esto no abre un agujero: `jobUser` **no concede ningún acceso a datos**.
Solo permite crear jobs. Una consulta contra `marts_ranchos` seguiría
fallando por falta de acceso a datos, no por falta de permiso de job — que
es justamente lo que prueba la verificación de más abajo.

### 3. Lectura, solo sobre L4

```bash
bq add-iam-policy-binding \
  --member="serviceAccount:bi-looker-reader@alba-analytics-ganaderia.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer" \
  -d alba-analytics-ganaderia:rpt_ranchos
```

`dataViewer` acotado con `-d` a un único dataset. No se otorga sobre
`ranchos` (L0), `stg_ranchos` (L1), `int_ranchos` (L2) ni `marts_ranchos`
(L3). Tampoco sobre `metadata_ranchos`, que contiene resultados de tests y
no es información de negocio.

### 4. Autorizar el dataset L4 sobre L3

Es el paso que hace que los 3 anteriores sirvan de algo (ver el hallazgo
arriba). No hay un comando de una línea: se edita la lista de `access` del
dataset.

```bash
# 4a. Exportar la configuración actual
bq show --format=prettyjson alba-analytics-ganaderia:marts_ranchos > /tmp/marts_ranchos.json
```

```bash
# 4b. Agregar esta entrada al array "access" del JSON, sin tocar las
#     entradas existentes:
#
#   {
#     "dataset": {
#       "dataset": {
#         "projectId": "alba-analytics-ganaderia",
#         "datasetId": "rpt_ranchos"
#       },
#       "targetTypes": ["VIEWS"]
#     }
#   }
```

```bash
# 4c. Aplicar
bq update --source /tmp/marts_ranchos.json alba-analytics-ganaderia:marts_ranchos
```

`targetTypes: ["VIEWS"]` restringe la autorización a las vistas del
dataset: solo los objetos de tipo vista de `rpt_ranchos` pueden leer
`marts_ranchos`. Hoy los 16 objetos de L4 son vistas, así que cubre todo.

**Cuidado al editar el JSON:** `bq update --source` reemplaza la
configuración completa del dataset. Si se borra por accidente una entrada
existente de `access` (por ejemplo la de `dw-dbt-runner` como OWNER), se
le quita el permiso al pipeline y el `dbt build` nocturno falla. Conservar
el archivo original antes de editar.

## Cómo conecta Looker Studio

El conector de BigQuery de Looker Studio ofrece autenticarse con las
credenciales del dueño del reporte o con una service account.

**Usar la service account** (`bi-looker-reader`) es lo que hace que todo
esto tenga sentido. Si el reporte se conecta con la cuenta personal del
dueño —que en este proyecto es owner de todo el proyecto GCP— entonces el
dashboard puede leer cualquier dataset y la separación de capas vuelve a
ser solo una convención.

Looker Studio necesita poder generar tokens en nombre de esa service
account, lo que requiere otorgarle `roles/iam.serviceAccountTokenCreator`
sobre `bi-looker-reader` a la identidad de servicio de Looker Studio.
**Ese identificador hay que leerlo de la propia interfaz de Looker Studio
al configurar la conexión** — cambia según el tipo de cuenta, y no
conviene adivinarlo acá: un binding IAM contra una identidad equivocada
falla de forma confusa (parece un problema de permisos del dataset cuando
en realidad es de impersonación).

## Verificación — el permiso acotado se prueba, no se asume

Dos consultas. **Una debe funcionar y la otra debe fallar** — si ambas
funcionan, el permiso quedó más ancho de lo previsto y la regla de
gobierno no está realmente aplicada.

```bash
TOKEN=$(gcloud auth print-access-token \
  --impersonate-service-account=bi-looker-reader@alba-analytics-ganaderia.iam.gserviceaccount.com)
```

**Debe devolver datos** (L4, permitido):

```bash
curl -s -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/alba-analytics-ganaderia/queries" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"query":"SELECT COUNT(*) AS n FROM `alba-analytics-ganaderia.rpt_ranchos.rpt_metrica_estado_reproductivo`","useLegacySql":false}'
```

**Debe fallar con `accessDenied`** (L3, prohibido — este es el test real
de la regla):

```bash
curl -s -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/alba-analytics-ganaderia/queries" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"query":"SELECT COUNT(*) AS n FROM `alba-analytics-ganaderia.marts_ranchos.fct_venta_leche`","useLegacySql":false}'
```

Conviene repetir la segunda contra `ranchos` (L0) y `stg_ranchos` (L1)
para confirmar que tampoco son alcanzables.

Para impersonar hace falta tener `roles/iam.serviceAccountTokenCreator`
sobre `bi-looker-reader`. Es el mismo mecanismo de impersonación que este
proyecto ya usa para verificar reglas de Firestore con usuarios reales
(ver el `CLAUDE.md` de `ranchos--app`): en vez de razonar sobre si el
permiso quedó bien, se ejecuta como esa identidad y se mira qué pasa.

## Estructura sugerida del dashboard

Cuatro páginas, alineadas a las métricas de la Fase 4. Cada una responde
una pregunta de negocio, no "muestra una tabla".

**1. Producción y precio de la leche** — `rpt_metrica_entrega_leche`.
Serie temporal de litros entregados y valor neto; encima, la evolución del
precio total por litro, que es la pregunta con más valor que estos datos
permiten (*¿me están pagando mejor o peor?*). Desglose del incentivo por
litro contra la multa. Recordar que el eje temporal es fecha de **pago**,
no de ordeño.

**2. Estado reproductivo del hato** — `rpt_metrica_estado_reproductivo`.
Conteo por estado como tarjetas (preñadas, vacías ciclando, anestro,
parió), un calendario de partos esperados con su fecha de preparto, y la
distribución de días abiertos — el indicador que más plata mueve en una
lechería.

**3. Evolución reproductiva** — `rpt_metrica_transicion_palpamiento`.
Mejoraron / mantienen / empeoraron por período, el desglose de
transiciones concretas, y una lista aparte de los posibles abortos.
Filtrar por `es_ultimo_palpamiento` para ver la foto actual en vez del
histórico completo.

**4. Finanzas** — `rpt_metrica_finanzas_mensual`. Resultado neto mensual
acumulado, gasto por categoría y clase, y comparación entre estación seca
y lluviosa. Usar siempre `resultado_neto`, nunca `monto_total`, que sin
signo mezcla ingresos con gastos.

`rpt_vacas_a_palpar` no va en el dashboard: es una planilla operativa para
exportar e imprimir, no un reporte para mirar en pantalla.

## Lo que este documento no cubre

- La construcción del dashboard en sí, que se hace en la interfaz de
  Looker Studio.
- La declaración del dashboard como `exposure` de dbt, para que el grafo
  de lineage llegue hasta el consumidor final. Se hace una vez que el
  dashboard exista y tenga URL (`models/marts/exposures.yml`, hoy vacío a
  la espera de justamente eso).
- Policy tags sobre columnas sensibles (por ejemplo montos de costo), que
  siguen pendientes como parte de la Fase 8 del documento de
  especificación.
