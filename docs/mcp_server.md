# Servidor MCP sobre el warehouse — diseño

**Fecha:** 2026-08-30
**Estado:** diseño para aprobar. **Sin código escrito todavía.**

Expone las métricas de L4 a un agente (Claude Desktop) como herramientas
de negocio acotadas. Vive en `mcp/` dentro de este mismo repo y no en uno
aparte: es un consumidor del warehouse, y mantenerlo acá conserva la
narrativa completa —de la réplica cruda hasta el consumidor final— en una
sola pieza.

## La decisión central: herramientas cerradas, no `run_query()` abierto

La alternativa obvia sería una sola herramienta que reciba SQL y lo
ejecute. Se descarta. Es el equivalente, para un agente, de la regla que
este proyecto ya aplica a BI: *no se consulta el warehouse a mano, se
consulta la capa curada*.

**1. Definiciones consistentes — la razón principal.** La capa de
métricas existe justamente para que "resultado neto" o "días abiertos"
signifiquen una sola cosa. Con SQL abierto, el agente inventaría su propia
versión en cada consulta: sumaría `monto_total` sin signar (mezclando
ingresos con gastos), o contaría como preñadas a las 14 vacas que ya
parieron. Ambos errores producen un número que *parece* correcto. Una
herramienta cerrada no puede cometerlos porque no decide la definición.

**2. No se puede salir de L4.** Con herramientas cerradas, el conjunto de
tablas alcanzables está fijo en el código y es auditable leyéndolo. Con
SQL abierto, la única barrera es el permiso IAM — y si algún día ese
permiso se otorga de más por error, no queda ninguna segunda línea de
defensa. Este proyecto ya vio permisos configurados de forma distinta a la
esperada (ver `docs/bi_looker_studio.md`, el hallazgo de las vistas
autorizadas); no conviene que la seguridad dependa de un solo control.

**3. Sin columnas alucinadas.** Un modelo que escribe SQL contra un
esquema que no tiene delante inventa nombres de columna plausibles. El
mejor caso es un error de sintaxis; el peor es una consulta que corre y
devuelve algo que no es lo que se preguntó.

**4. Auditabilidad.** Se puede responder "¿qué preguntas puede contestar
este agente?" leyendo el catálogo de herramientas. Con SQL abierto, la
respuesta es "cualquiera que se le ocurra", que no es una respuesta.

**5. Costo — un argumento honesto, hoy menor.** Suele citarse el costo
como razón principal. Acá no lo es: **toda la capa `marts_ranchos` pesa
0.9 MB**, y BigQuery factura un mínimo de 10 MB por consulta. Con este
volumen, una consulta descontrolada no genera una factura preocupante. El
argumento aplica al futuro (el warehouse crece) y a consultas no acotadas,
no a la factura de hoy. Igual se pone un tope de bytes facturados como
seguro barato.

### Lo que se pierde

**Flexibilidad.** Una pregunta que no encaje en ninguna herramienta no se
puede responder, aunque los datos estén ahí. Con SQL abierto, sí.

**Una herramienta nueva por cada pregunta nueva.** Cada capacidad
adicional es un cambio de código, revisión y despliegue — no un prompt
distinto. Es un costo real de mantenimiento, y se acepta a cambio de los
4 puntos de arriba.

El punto medio (dejar que el agente elija columnas, filtros o agrupaciones
libres sobre una tabla fija) se evita a propósito: es el primer paso hacia
construir SQL desde texto libre, y reintroduce los problemas 1 y 3 sin
recuperar del todo la flexibilidad.

## Catálogo de herramientas

Una por métrica de la Fase 4. Cada `description` sale de la del modelo en
su YAML de dbt — se escribieron pensando en que las lea un modelo de
lenguaje que no conoce el negocio, así que se reutilizan en vez de
redactar una segunda versión que se desincronice.

**El grano determina los parámetros.** Tres de las seis herramientas no
reciben rango de fechas: consultan métricas de estado actual, donde un
rango no significa nada. Es una consecuencia directa de haber declarado el
grano de cada modelo.

### 1. `consultar_entregas_leche`

Vista: `rpt_metrica_entrega_leche` · Grano: una entrega.

| Parámetro | Tipo | Req. | Notas |
|---|---|---|---|
| `desde` | date | sí | Filtra `fecha_pago` |
| `hasta` | date | sí | |
| `finca` | string | no | |

Responde cuánta leche se entregó, cuánto se cobró y cómo evoluciona el
precio por litro. La descripción advierte que la fecha es de **pago**, no
de ordeño — un agente que no lo sepa respondería mal una pregunta sobre
estacionalidad productiva.

### 2. `consultar_estado_reproductivo`

Vista: `rpt_metrica_estado_reproductivo` · Grano: una hembra activa
palpada. **Sin rango de fechas** (estado actual).

| Parámetro | Tipo | Req. | Notas |
|---|---|---|---|
| `finca` | string | no | |
| `estado` | enum | no | `Preñada`, `Parió`, `Vacía Ciclando`, `Vacía Anestro` |
| `lote` | string | no | |

El enum de `estado` es cerrado a propósito: son los 4 valores que el
modelo puede producir, verificados con un test `accepted_values`. Un
agente no puede pedir un estado inexistente y recibir cero filas
interpretándolas como "no hay ninguna".

### 3. `consultar_vacas_a_palpar`

Vista: `rpt_vacas_a_palpar` · Grano: una vaca pendiente. **Sin rango de
fechas** (lista de trabajo actual).

| Parámetro | Tipo | Req. | Notas |
|---|---|---|---|
| `finca` | string | no | |
| `lote` | string | no | |

Las 2 columnas de captura en campo (`fecha_palpamiento_nuevo`,
`resultado_palpamiento_nuevo`) **se excluyen de la respuesta**: son
siempre nulas por diseño, y devolverlas solo invitaría al agente a
explicar por qué están vacías.

### 4. `consultar_transiciones_palpamiento`

Vista: `rpt_metrica_transicion_palpamiento` · Grano: un palpamiento.

| Parámetro | Tipo | Req. | Notas |
|---|---|---|---|
| `desde` | date | sí | Filtra `fecha_palpamiento` |
| `hasta` | date | sí | |
| `finca` | string | no | |
| `transicion` | enum | no | `Primer palpamiento`, `Mejoró`, `Mantiene`, `Empeoró`, `Ciclo completado` |
| `solo_posibles_abortos` | bool | no | Atajo para `posible_aborto = true` |

### 5. `consultar_finanzas_mensual`

Vista: `rpt_metrica_finanzas_mensual` · Grano: finca + mes + tipo +
categoría + clase.

| Parámetro | Tipo | Req. | Notas |
|---|---|---|---|
| `desde` | string `YYYY-MM` | sí | La vista no tiene columna de fecha: se filtra sobre `anio`/`mes` |
| `hasta` | string `YYYY-MM` | sí | |
| `finca` | string | no | |
| `tipo_transaccion` | enum | no | `Entrada`, `Salida`, `Inversion` |
| `categoria` | string | no | |

La descripción debe insistir en usar `resultado_neto` y no `monto_total`
para sumar: sin signo, este último mezcla ingresos con gastos.

### 6. `consultar_existencia_insumos`

Vista: `rpt_metrica_existencia_insumo` · Grano: un insumo por finca.
**Sin rango de fechas** (saldo actual).

| Parámetro | Tipo | Req. | Notas |
|---|---|---|---|
| `finca` | string | no | |
| `categoria` | string | no | |
| `solo_negativos` | bool | no | Insumos con existencia imposible — delatan captura errónea |

## Modelo de seguridad

**Service account propia: `mcp-agent-reader`**, con exactamente el mismo
recorte que la de BI: `roles/bigquery.jobUser` a nivel proyecto (los jobs
son recurso de proyecto, no de dataset) y `roles/bigquery.dataViewer`
**solo** sobre `rpt_ranchos`.

Es una identidad separada de `bi-looker-reader` a propósito, aunque los
permisos sean idénticos:

- **Radio de impacto**: revocar el acceso del agente no debe apagar los
  dashboards, ni al revés.
- **Rastro de auditoría**: los logs de jobs de BigQuery muestran qué
  identidad ejecutó qué. Con una sola cuenta compartida, no se puede
  distinguir una consulta del agente de una del dashboard.

**La arquitectura de un dataset por capa funciona acá como política de
seguridad del agente.** No hay un mecanismo nuevo: el mismo aislamiento
que existe desde la Fase 2 es lo que hace que el agente no pueda alcanzar
datos crudos aunque quisiera. Requiere el dataset autorizado del paso 4 de
`docs/bi_looker_studio.md` — sin eso las vistas de L4 no pueden leer L3 y
ninguna herramienta funciona.

**Verificación**, con el mismo par de consultas por impersonación que
documenta el acceso de BI: una contra L4 que debe funcionar y una contra
`marts_ranchos` que **debe fallar con `accessDenied`**. Si ambas
funcionan, el recorte no está aplicado.

## Límites y comportamiento en el borde

| Límite | Valor | Por qué |
|---|---|---|
| Filas por respuesta | 500 | Cubre con holgura cualquier consulta razonable (la vista más grande tiene 310 filas) sin inundar el contexto del agente |
| Rango de fechas | 24 meses | Cubre todo el histórico disponible hoy (el más largo son 20 meses) |
| Bytes facturados | 100 MB | ~100× toda la capa marts. Nunca se alcanza en uso normal; existe como corte ante un futuro descontrolado |

**Al exceder un límite, la herramienta devuelve un error explicando cuál
se excedió y sugiriendo un rango más angosto. Nunca trunca en silencio.**

Es la decisión más importante de esta sección. Si devolviera las primeras
500 filas sin avisar, el agente sumaría sobre datos parciales y reportaría
el total con total confianza — un error indetectable para quien lee la
respuesta. Un error explícito hace que el agente reformule; una
truncación silenciosa hace que mienta.

## Fuera de alcance de la versión 1

- **Nada de escritura.** Solo lectura. El agente no crea, corrige ni borra
  registros, ni en el warehouse ni en la app operacional.
- **Nada fuera de L4.** Sin acceso a marts, staging, snapshots, raw ni
  `metadata_ranchos`.
- **Nada de la app operacional.** El agente no toca `ranchos--app`,
  Firestore ni las Cloud Functions.
- **Sin despliegue.** Transporte stdio, local, autenticado con ADC.
  Desplegar a Cloud Run queda para una ronda posterior: implica exponer un
  endpoint, resolver autenticación de red y decidir quién puede invocarlo,
  decisiones que no corresponden a esta fase.
- **Sin agrupaciones dinámicas.** Las herramientas devuelven filas al
  grano de su vista; agregar es responsabilidad del agente. Un parámetro
  de `group by` sería el primer paso hacia construir SQL desde texto
  libre.

## Entregables al implementar

- `mcp/server.py` — servidor con el SDK oficial de MCP, transporte stdio.
- `mcp/README.md` — cómo conectarlo a Claude Desktop, y 3-4 preguntas de
  ejemplo para probarlo.
- Dependencias agregadas sin romper el CI actual: `dbt parse` debe seguir
  pasando (ver `.github/workflows/ci.yml`).
