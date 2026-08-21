# Fase 5 (parcial) — Validar que Firestore se copió correctamente a raw

**Fecha:** 2026-08-13
**Alcance:** controles de calidad para responder específicamente "¿los datos
de Firestore se copiaron a raw?" — no la Fase 5 completa del documento de
especificación (persistencia de tests ya cubierta acá para estos controles
puntuales; detección automática de anomalías sobre volumen/distribución
queda para una iteración futura, ver "Fuera de alcance" al final).

## Por qué esto no es 1 solo hop, es 2

Firestore → `ranchos-7c313` (tablas operacionales) → `alba-analytics-ganaderia:ranchos`
(raw, L0 de este repo). dbt/BigQuery no tienen forma de leer Firestore
directo — el primer hop (Firestore → `ranchos-7c313`) ya está cubierto por
las Cloud Functions de sync de `ranchos--app` (triggers `onCreate`/
`onUpdate`/`onDelete` con DML directo, ver `docs/fase0_inspeccion.md`
sección 0.4) y es responsabilidad de ese repo, no de este. Lo que este
repo SÍ puede — y debe — verificar es el segundo hop: que la réplica
`raw` sea fiel a `ranchos-7c313` en cada momento.

## Qué se implementó

### 1. Reconciliación de conteo — `tests/generic/test_reconciliacion_conteo_raw_vs_operacional.sql`
Test genérico aplicado a las 26 tablas de `sources.yml`: compara el conteo
EXACTO de filas de cada tabla en `raw` contra la misma tabla en un source
nuevo, `ranchos_operacional` (apunta a `ranchos-7c313:ranchos`, la fuente
real — ver comentario extenso en `_ranchos__sources.yml`). Falla si no
coinciden.

- **Hallazgo técnico de diseño:** el primer intento usaba
  `model.identifier` (calculado dentro del macro) para derivar
  dinámicamente el nombre de la tabla operacional correspondiente — dbt lo
  rechazó en tiempo de parseo con un error de source "no encontrado" y un
  nombre mangled, porque el analizador estático de dbt (que arma el grafo
  de dependencias sin ejecutar Jinja) no puede resolver un `source()`
  llamado con un argumento dinámico. Se corrigió pasando el `source(...)`
  ya resuelto como argumento explícito desde el YAML — mismo patrón que
  ya usa el test `relationships` nativo de dbt en este mismo archivo
  (`to: source('ranchos', 'tabla')`).
- **Resultado real:** 26/26 tablas reconciliadas exacto — `raw` es hoy una
  réplica 100% fiel de `ranchos-7c313`.

### 2. `dbt source freshness` — antes no computaba nada
`sources.yml` ya declaraba `loaded_at_field` por tabla desde la migración
original, pero nunca se le habían configurado umbrales
(`warn_after`/`error_after`) — `dbt source freshness` corría pero no
evaluaba nada ("Nothing to do"). Se agregaron umbrales reales:

- **2 niveles, no 1 solo para las 26 tablas** — probado empíricamente: un
  umbral parejo de 3 días warn / 10 días error marcó 18 de 26 tablas como
  stale, la mayoría catálogos que por diseño casi no cambian (ej.
  `tb_dim_fincas`, 1 sola fila desde siempre). Ajustado a: default del
  source (dims/catálogos) 14 días warn / 45 días error; override por
  tabla en cada `tb_fact_*` (captura operacional activa) 5 días warn / 14
  días error.
- **Bug técnico real encontrado y corregido:** las tablas DIM usan
  columnas `DATE` (`fecha_creacion`/`fecha_registro`) como
  `loaded_at_field`, pero el mecanismo de `source freshness` de
  dbt-bigquery exige `TIMESTAMP` — sin corregirlo, fallaba con
  `Database Error: Expected a timestamp value... but received value of
  type 'date'` en vez de calcular un estado real. Corregido envolviendo
  esas 14 columnas con `cast(... as timestamp)` directamente en
  `loaded_at_field` (dbt permite que ese campo sea cualquier expresión
  SQL válida, no solo un nombre de columna).
- **Ninguno de los 2 umbrales está calibrado contra el patrón real de
  actividad de esta finca en particular** — son un punto de partida
  técnicamente razonable (separar dims de facts), documentado como tal en
  `_ranchos__sources.yml`. Resultado actual (informativo, no un bug):
  15/26 PASS, 4 WARN, 7 ERROR STALE — los 7 en error son 5 tablas fact de
  captura menos frecuente (palpamientos, partos, salidas, pesaje_leche,
  tratamientos) más 2 catálogos casi estáticos (`tb_dim_fincas`,
  `tb_dim_roles`) que probablemente nunca deberían evaluarse por
  freshness en primer lugar, dado que por diseño casi no cambian.

### 3. Persistencia de fallos — `metadata_ranchos`
Los 26 tests de reconciliación tienen `store_failures: true` +
`schema: metadata_ranchos` — confirmado empíricamente (no solo
configurado) que esto crea 26 tablas de resultados en
`dev_metadata_ranchos` en cada corrida, con las filas que fallaron (0 hoy,
ya que las 26 reconciliaciones pasan). Es el dataset reservado desde la
Fase 2 (`docs/fase2_arquitectura.md`) que hasta ahora no tenía ninguna
escritura real — con esto empieza a cumplir su propósito: "esa serie
histórica es el insumo para reportar la evolución de la calidad del
dato" (Fase 5 del documento de especificación).

## Verificación

- `dbt build` del proyecto completo: **348/348 tests** (322 anteriores +
  26 de reconciliación nuevos).
- `dbt source freshness`: corre sin errores técnicos sobre las 26 tablas
  (antes: 19 `Database Error` de tipo).
- `metadata_ranchos` confirmado con contenido real (26 tablas de
  resultados) vía `bq ls` directo, no solo asumido por la configuración.
- `sqlfluff lint`: limpio.

## Fuera de alcance de este pase (Fase 5 completa queda pendiente)
- Detección automática de anomalías sobre volumen de filas/distribución
  de columnas (cubre "una colección dejó de sincronizar sin ningún
  error" — el propio pipeline EL ya corre 3x/día y sobreescribe completo,
  así que un fallo de sync real hoy ya se vería reflejado en la
  reconciliación de conteo; una herramienta de anomalías agregaría
  detección más temprana/granular, no reemplaza lo que ya existe).
- El resto de las dimensiones de calidad de la tabla de la Fase 5
  (Exactitud, Consistencia insumos ledger-vs-conteo) — aplican dentro del
  warehouse (staging→marts), no a la pregunta puntual de esta sesión
  ("¿se copió Firestore a raw?").
- Calibración fina de los umbrales de freshness contra el patrón real de
  actividad de la finca piloto — pendiente de observar en la
  práctica.

## Estado
Cumple el pedido puntual de esta sesión. Sin Punto de Control obligatorio
del documento en este punto — sigue disponible continuar con el resto de
la Fase 5 (anomalías) o pasar a la Fase 6 (alarmas) cuando se decida.
