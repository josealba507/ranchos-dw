# Fase 0 — Informe de inspección del proyecto existente

**Fecha:** 2026-08-13
**Alcance:** respuesta a la especificación conceptual de DW por capas, sección
"Fase 0". No se escribió código de producción durante esta fase — solo
lectura de `ranchos--app` (Firestore, `functions/src`, `firestore.rules`) y
de la infraestructura de BigQuery de ambos proyectos GCP.

---

## 0.1 Convenciones de código y datos

- **Idioma: mezclado con una regla implícita muy consistente** — términos de
  dominio en español (`finca_asociada`, `arete`, `estado_gestacion`,
  `movimientos_insumos`), términos técnicos/de patrón en inglés
  (`renderHatoInventario`, `startEditPalpamiento`, `writeBatch`,
  `onSnapshot`). No hay una sola colección, campo de negocio o mensaje de
  usuario en inglés en todo `public/index.html`.
- **Casing de campos en Firestore: `snake_case` sin excepciones.**
  Verificado por grep exhaustivo (`id_animal`, `finca_asociada`,
  `timestamp_registro`, `fecha_nacimiento`, `tipo_transaccion`,
  `monto_total`, `estado_registro`, etc.) — no hay un solo campo
  `camelCase` en los documentos de negocio. Esto es inusual para Firestore
  (la convención de la comunidad es `camelCase`) pero deliberado: el
  proyecto pensó el data warehouse desde el día uno, incluso antes de que
  este repo existiera (`CLAUDE.md` de `ranchos--app`, sección "Convención
  de datos": *"Ya se usa nomenclatura tipo data warehouse en algunas
  colecciones"*).
- **No existe CONTRIBUTING.md ni documento de convenciones separado.**
  `CLAUDE.md` de `ranchos--app` cumple esa función de facto — es extenso,
  aunque no siempre exacto (ver 0.4 y hallazgo de `foto_url` ya corregido
  en una sesión anterior de este mismo repo).
- **No hay capa de repositorio/acceso a datos nombrada.** Cada handler de
  formulario llama `addDoc`/`setDoc`/`onSnapshot` directo sobre
  `collection(db, "artifacts", appId, "public", "data", "<coleccion>")` —
  sin abstracción, sin un archivo por colección. El "nombre" de cada fuente
  de datos es simplemente el string literal de la colección, repetido en
  cada punto de uso (listener, alta, edición). No hay un patrón que
  replicar aquí más allá de "el nombre de colección es la única fuente de
  verdad de nomenclatura, no hay una capa intermedia que renombre".

## 0.2 Modelo de datos operacional

**22 colecciones top-level bajo `artifacts/{appId}/public/data/`**
(confirmado por grep exhaustivo de `collection(db, "artifacts", appId,
"public", "data", "...")`, no por documentación):

| Colección | Tipo | Nota |
|---|---|---|
| `fincas` | dim | multi-tenant root |
| `roles` | dim | catálogo de roles del sistema |
| `usuarios` | dim | roster administrable de colaboradores |
| `finanzas` | fact | **comparte tabla con Venta de Leche** — discriminada por `tipo_registro` |
| `logs` | fact | bitácora de auditoría, no un changelog CDC (ver 0.4) |
| `catalogo_finanzas` | dim | categoría/clase de gasto, editable por finca |
| `animales` | dim | inventario de hato — SCD real (lote/categoría/estado cambian en la vida del animal) |
| `partos` | fact | nacimientos |
| `palpamientos` | fact | diagnóstico reproductivo, con `estado_gestacion` (Activo/Parió/Aborto) |
| `catalogo_veterinarios` | dim | alta automática |
| `pesajes_leche` | fact | litros por vaca por ordeño — grano más fino que Venta de Leche |
| `salidas` | fact | bajas/ventas de animales, muta `animales.estado` |
| `catalogo_motivos_salida` | dim | alta automática + 2 valores fijos |
| `catalogo_lotes` | dim | única con alta+edición+borrado completos junto a Unidades de Insumos |
| `catalogo_categorias_animal` | dim | alta automática |
| `tratamientos` | fact | eventos sanitarios |
| `catalogo_medicinas` | dim | alta automática |
| `catalogo_motivos_tratamiento` | dim | alta automática |
| `catalogo_insumos` | dim | inventario de insumos — presentación es texto descriptivo, no factor |
| `catalogo_categorias_insumos` | dim | alta automática |
| `catalogo_unidades_insumos` | dim | alta+edición+borrado — 5 unidades fijas + custom por finca |
| `movimientos_insumos` | fact | ledger inmutable (inicial/compra/conteo/merma/ajuste) — **grano: un movimiento** |
| `periodos_consumo_insumos` | fact | **el dataset de entrenamiento para el modelo predictivo que pide la Fase 7** — ya existe hoy, calculado client-side |

Más una subcolección fuera de ese árbol: **`artifacts/{appId}/users/{uid}/perfil/datos`**
— el perfil ligado a Firebase Auth (1 doc por usuario autenticado), distinto
de `usuarios` (el roster administrable). Ambos coexisten: `usuarios` es lo
que un admin edita desde Accesos; `perfil` es lo que el propio usuario "es"
al loguearse, y alimenta los custom claims (`syncCustomClaimsOnPerfilWrite`)
que usa `storage.rules`.

**IDs de documento:** mixtos, con una regla dura y consistente donde aplica.
Colecciones con clave natural forzada por `firestore.rules` (el campo debe
ser *idéntico* al docId — regla establecida desde PR #48 de `ranchos--app`
específicamente para que ese campo no pueda usarse para "pisar" el estado
de un registro ajeno vía los triggers de sync): `roles.id_rol`,
`fincas.id_finca`, `animales.id_animal`, y `id_registro` en toda tabla fact
versionada (finanzas/leche/hato/veterinaria). El resto usa docId
autogenerado de Firestore sin campo espejo.

**Lote/hato y finca/potrero:**
- **Lote de Manejo** (agrupación de vacas) existe — colección
  `catalogo_lotes`, campo `lote` (texto, no FK) en `animales`.
- **"Hato"** no es una colección — es el nombre del módulo de navegación
  que agrupa Inventario/Registrar/Administración de `animales`+`partos`+
  `salidas`. El "hato" completo de una finca = `animales` filtrado por
  `finca_asociada`.
- **Finca** existe como entidad real (`fincas`). **No existe "potrero"**
  como entidad de datos — la única aparición de la palabra en todo el
  repo es un uso coloquial ("capataz puede registrar en el potrero") en un
  comentario de `firestore.rules`, no un campo ni colección.
- Confirmado: **multi-finca real**, discriminador `finca_asociada`
  presente en prácticamente todas las colecciones no-globales (excepción:
  `roles`, que es un catálogo compartido entre fincas).

**Borrado:** mixto, por diseño, no por descuido:
- **Soft-delete vía `estado`** (Activo/Inactivo, o valores de negocio como
  Vendido/Muerto para animales vía `salidas`): la mayoría de los
  catálogos y `animales`.
- **Hard-delete permitido** en Firestore para algunos catálogos
  (`catalogo_lotes`, `catalogo_unidades_insumos`, `catalogo_categorias_insumos`,
  `catalogo_finanzas`, `animales`) — pero en TODOS los casos, el trigger de
  sync a BigQuery convierte ese hard-delete en soft-delete
  (`softDeleteDimRow`, `estado='Inactivo'`) del lado del warehouse. **La
  capa raw nunca ve un DELETE físico**, aunque Firestore sí lo tenga.
- **Fact tables nunca se hard-deletean** (excepto `pesajes_leche`, la
  única fact con `delete` habilitado — marca `'Anulado'` en BigQuery en
  vez de borrar).

**Dinero — conflicto directo con el documento, ver sección "Inconsistencias".**
`monto: parseFloat(...)` en el cliente (`<input type="number" step="0.01">`),
tipo `NUMERIC` (no `FLOAT64`, no `INT64`) en BigQuery. **No son centavos
enteros.**

**Unidades y factores de conversión — estado real más simple de lo que el
documento asume, y ya migrado deliberadamente:** el módulo de Insumos SÍ
tuvo en su día un `factor` de conversión por presentación (`presentaciones[]`),
pero fue el origen de un bug real en producción (inflaba existencias x15/
x50/x100 cuando la unidad base era un contenedor personalizado, no una
unidad física estándar) y **se eliminó por completo** — hoy `presentacion`
es un string puramente descriptivo, sin factor, y cada presentación
distinta de un producto es su propio ítem de catálogo. El campo
`factor_presentacion_copiado` sigue existiendo en `movimientos_insumos`
por compatibilidad de esquema, pero **siempre vale `1`** desde ese cambio.
La regla del documento ("el factor de conversión va denormalizado en cada
movimiento, no se re-deriva") ya no tiene objeto que denormalizar — no
hay factor que preservar, la cantidad se captura siempre directo en
`unidad_base`.

## 0.3 Manejo del tiempo — hallazgo central de esta fase

**Sí existe fecha de evento propia, separada del timestamp de registro, en
absolutamente todas las fact tables** — no es un hallazgo bloqueante como
el documento anticipaba como escenario posible. Cada colección fact tiene
su propio nombre de campo de negocio (no hay un nombre único compartido):
`fecha_pago`/`fecha_transaccion` (finanzas/leche), `fecha_muestra`
(microbiología/composición), `fecha_pesaje`, `fecha_nacimiento` (partos),
la fecha del formulario de Palpamiento/Tratamiento/Salidas, `fecha_conteo`
(insumos).

**Pero surge un problema distinto, más sutil, no anticipado por el
documento en estos términos — dónde está el verdadero "timestamp de
sincronización":**

- **Ningún punto del código usa `serverTimestamp()` de Firestore.** Cero
  ocurrencias en `public/index.html` (verificado por grep exhaustivo).
- `timestamp_registro` (fact) / `fecha_creacion` (dim) se asignan como
  `new Date().toISOString()` — **con el reloj del dispositivo, en el
  cliente**, en el momento en que se llena el formulario, no en el momento
  en que el documento realmente llega a Firestore.
- Los triggers de sync (`syncAnimalOnCreate` y equivalentes) sí tienen
  acceso a `context.timestamp` — el timestamp real del evento de Firestore,
  asignado por el servidor en el momento del commit — pero **solo lo usan
  como fallback** (`data.fecha_creacion || toDateOnly(context.timestamp) || ...`).
  Como el cliente siempre manda un valor, ese fallback nunca se activa en
  la práctica.

**Consecuencia concreta:** para una captura offline (el escenario central
que motiva toda la Fase 3 del documento), `timestamp_registro` refleja el
momento en que el colaborador llenó el formulario en el potrero — no el
momento en que ese dato realmente se volvió consultable en BigQuery, que
puede ser horas o días después, cuando el dispositivo recupera señal. Para
capturas online ambos momentos casi coinciden (diferencia de milisegundos);
para capturas offline, **no hay ningún campo en el esquema actual que
capture el verdadero momento de disponibilidad server-side.**

Esto no bloquea la construcción de staging/marts/alertas (`timestamp_registro`
sigue siendo una aproximación razonable — "cuándo se capturó", que es
justo la métrica de calidad operativa que el documento pide en 3.2). **Sí
es un hallazgo bloqueante específicamente para la Fase 7 (ML):** la regla
de corrección punto-en-el-tiempo exige recortar por el timestamp real de
sincronización, y hoy ese dato no existe de forma confiable — usar
`timestamp_registro` como proxy sería optimista/con fuga para cualquier
registro capturado offline, exactamente el riesgo que la Fase 7 nombra
explícitamente. Ver recomendación en "Riesgos".

## 0.4 Infraestructura de replicación existente

- **No es la extensión oficial "Stream Firestore to BigQuery".** Se
  probó en algún momento y se descartó (`CLAUDE.md` de `ranchos--app`);
  `firebase ext:list` da cero extensiones instaladas hoy.
- **Es un pipeline 100% propio, y NO es un patrón de changelog/CDC** — esto
  cambia sustancialmente el alcance de la Fase 3 del documento (ver
  "Inconsistencias" más abajo). Cada colección tiene 1-3 Cloud Functions
  (`onCreate`/`onUpdate`/`onDelete`) que ejecutan **DML directo**
  (`INSERT`/`UPDATE` vía `@google-cloud/bigquery`, nunca streaming insert
  — BigQuery bloquea `UPDATE`/`DELETE` sobre filas en el streaming buffer
  hasta ~90 min, lo cual rompía las correcciones). No existe una tabla de
  changelog append-only en ningún punto del pipeline.
- **Versionado histórico ya resuelto del lado de la fuente, no en el
  warehouse:** las tablas fact usan `estado_registro`
  (`Activo`/`Corregido`/`Anulado`) — al corregir un registro, la fila
  vigente pasa a `Corregido` y se inserta una fila nueva `Activo`; al
  borrar, pasa a `Anulado`. **La deduplicación que pide la Fase 3.1 del
  documento (particionar por id, quedarse con la última fila) ya está
  resuelta en origen** — un modelo de staging solo necesita
  `WHERE estado_registro = 'Activo'` para tener el estado vigente, sin
  necesitar ningún `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)`
  contra un changelog.
- **Proyectos:** `ranchos-7c313` (operacional, fuente) →
  `alba-analytics-ganaderia` (warehouse). Ya separados, ya migrados (ver
  historial de este mismo repo). Dataset `ranchos` en ambos lados.
- **26 tablas reales hoy** en el dataset origen (creció de 19 a 26 desde
  la migración inicial de este repo — el módulo de Insumos y los
  catálogos nuevos de Hato se sumaron después). La réplica en
  `alba-analytics-ganaderia` ya las tiene las 26 — el transfer "Dataset
  Copy" es adaptativo al esquema, no requirió ninguna acción manual.
  **Pendiente de este repo, no de este informe:** `sources.yml` solo
  declara las 19 originales — hay que sumar las 7 nuevas.
- **No existe ningún modelo, vista ni consulta programada previa a este
  repo** en `ranchos-7c313` ni en `alba-analytics-ganaderia` — dataform.googleapis.com
  está habilitado en `ranchos-7c313` pero sin ningún repositorio Dataform
  real (confirmado vía API, respuesta vacía) — probablemente quedó
  habilitado al explorar BigQuery Studio alguna vez, sin usarse.

## 0.5 Consumo actual

- **No hay tableros ni reportes formales conocidos.**
- **Sí hay consumo manual existente que este documento debe tener en
  cuenta:** 4 vistas creadas directo en BigQuery Console sobre la réplica
  (`VS_001_VENTA_LECHE`, `VS_002_TRANSACCION_FINANCIERA_AGRUPADA`,
  `VS_004_DETALLE_TRANSACCION_FINANCIERA`, `VS_OO3_TRANSACCION_FINANCIERA_DIARIA`
  — nombres con inconsistencias propias, ej. "OO3" en vez de "003"). No
  están documentadas en ningún CLAUDE.md ni versionadas — viven solo como
  objetos de BigQuery. Sobrevivieron sin problema la corrida automática
  del transfer con `overwrite_destination_table=true` (confirmado
  empíricamente), pero **quedan fuera del alcance de este documento
  (marts/L3-L4)** hasta que se audite qué contienen y si conviene
  reemplazarlas por marts reales o dejarlas como están.
- **Cero consultas de la app contra BigQuery** — confirmado por grep:
  todas las menciones a "BigQuery" en `public/index.html` son comentarios
  explicando que el sync ocurre server-side. La regla "la app nunca
  consulta el warehouse" ya se cumple hoy, no hay nada que reemplazar por
  el patrón de reverse ETL — solo hay que construirlo para las alertas
  nuevas que pida la Fase 6.

---

## Inconsistencias detectadas (por severidad)

1. **[Alta] Conflicto directo con "Decisiones ya tomadas" del documento —
   dinero NO son enteros en centavos.** El proyecto ya evaluó
   explícitamente esta convención (documento de diseño de Insumos, con
   pregunta formal al usuario) y **decidió a propósito mantener
   float/`NUMERIC`** por consistencia con Finanzas y Venta de Leche, que
   son anteriores y ya estaban en producción. Regla 4 del documento: gana
   el proyecto. Propuesta: mantener `NUMERIC` (BigQuery decimal exacto,
   sin los problemas de `FLOAT64`) en todo el warehouse — es
   estrictamente mejor que enteros-en-centavos para este caso (evita una
   capa de conversión ida y vuelta sin necesidad, y el negocio ya piensa
   y muestra los valores en dólares con decimales, nunca en centavos).
2. **[Alta] La Fase 3 del documento (changelog/CDC) asume un mecanismo de
   replicación que este proyecto no tiene.** No hay tabla de changelog
   append-only, no hay vista `latest` de una extensión, no hace falta
   deduplicar por `ROW_NUMBER()`. El versionado (`estado_registro`) ya
   resuelve el mismo problema en origen. La Fase 3.1 y 3.4 del documento
   no aplican tal cual — se adaptan a "filtrar por `estado_registro =
   'Activo'`", que es más simple, no más complejo.
3. **[Media] No existe un campo confiable de "timestamp de sincronización
   real"** (ver 0.3) — `timestamp_registro`/`fecha_creacion` son
   capturados en el cliente, no en el servidor, pese a que el servidor sí
   tiene el dato disponible (`context.timestamp`) y simplemente no lo usa
   como prioridad. No bloquea Fases 0-6; sí bloquea la corrección
   punto-en-el-tiempo de la Fase 7 tal como está especificada.
4. **[Media] `factor_presentacion_copiado` en `movimientos_insumos` es
   vestigial** — existe en el esquema pero siempre vale `1` desde que se
   corrigió el bug que motivó su eliminación funcional. Cualquier
   documentación/test que lo trate como un factor real de conversión
   estaría documentando un comportamiento que ya no ocurre.
5. **[Baja] 4 vistas manuales sin documentar en BigQuery** (`VS_*`) —
   consumo real preexistente, sin gobierno, con un typo en un nombre
   (`VS_OO3` vs `VS_003`). No es bloqueante, pero hay que decidir qué
   hacer con ellas antes de dar la capa L4 por completa (¿se reemplazan
   por marts reales, se dejan como están, se documentan y versionan?).
6. **[Baja] `dataform.googleapis.com` habilitado sin uso** en
   `ranchos-7c313` — no es un problema, solo un cabo suelto a limpiar
   eventualmente (no bloquea nada, no cuesta nada estando inactivo).

## Riesgos bloqueantes

- **Ninguno bloquea el arranque de las Fases 1-6.** La app captura fecha
  de evento consistentemente, el mecanismo de replicación ya resuelve
  versionado/deduplicación, y no hay queries directas de la app al
  warehouse que haya que desmontar primero.
- **Un riesgo bloquea específicamente la Fase 7 (ML) tal como está
  redactada:** sin un timestamp de sincronización server-side confiable,
  la corrección punto-en-el-tiempo no se puede garantizar para registros
  capturados offline. Dos caminos, ninguno ejecutable sin cruzar a
  `ranchos--app` con confirmación explícita del usuario (regla ya
  establecida en `CLAUDE.md` de este repo):
  1. Agregar un campo nuevo (ej. `timestamp_sync_real`) poblado desde
     `context.timestamp` en cada trigger de sync — cambio aditivo, bajo
     riesgo, pero requiere tocar `functions/src/index.ts` de la app
     operacional.
  2. Aceptar `timestamp_registro` como aproximación documentada y
     revisar el riesgo real recién cuando la Fase 7 esté efectivamente
     en construcción (es la fase más lejana del plan; no hay urgencia de
     resolverlo hoy).

---

## Propuesta de nomenclatura (Fase 1)

| Decisión | Propuesta | Justificación anclada en el repo |
|---|---|---|
| Idioma de identificadores | **Español para entidades/campos de negocio, inglés para patrones técnicos** (`stg_`, `dim_`, `fct_`, `int_` se quedan en inglés porque son la convención universal de dbt/Kimball; `animal`, `finca`, `movimiento_insumo` en español) | Es exactamente el patrón ya vigente en `ranchos--app` (0.1) — no introduce un idioma nuevo, extiende el que ya existe. |
| Casing en BigQuery | **`snake_case`**, preservando 1:1 los nombres de campo que ya vienen de Firestore (`finca_asociada`, `id_animal`, `monto_total`...) en `staging/`, sin traducirlos | Firestore YA usa `snake_case` en este proyecto (0.1) — no hay conversión camelCase→snake_case que hacer, a diferencia del caso genérico que el documento anticipa. Alternativa descartada: renombrar en staging de todas formas por prolijidad — se descarta porque rompería el mapeo 1:1 que exige la Fase 2 del documento (staging = passthrough, cero lógica). |
| Prefijos de capa | `stg_` / `int_` / `dim_` / `fct_` (dbt estándar) | Ya en uso en este mismo repo (`stg_ranchos__animales`, `dbt_project.yml` con `+materialized` por carpeta `staging/intermediate/marts`). No hay razón para desviarse de una convención ya adoptada y funcionando. |
| Separador fuente-entidad en staging | **Doble guion bajo** (`stg_ranchos__animales`) | Ya en uso — es el nombre real del único modelo existente en este repo. |
| Singular o plural | **Singular** (`dim_animal`, no `dim_animales`; `fct_movimiento_inventario`, no `fct_movimientos_inventario`) | Convención Kimball/dbt estándar (una fila = una entidad). Alternativa: mantener plural en español natural (`dim_animales`, como ya se llama la colección Firestore) — es defendible porque el proyecto ya usa plural en Firestore (`animales`, `partos`, `salidas`) y en BigQuery raw (`tb_dim_animales`). **No hay una respuesta claramente superior acá** — recomiendo singular por ser el estándar dbt/Kimball que el resto del repo ya sigue en el nivel de prefijo, pero es la decisión más débil de esta tabla y vale confirmarla explícitamente. |
| Nombres de datasets (uno por capa) | `raw_ranchos` (o mantener `ranchos` tal cual como L0 sin renombrar), `stg_ranchos`, `int_ranchos`, `marts_ranchos`, `metadata_ranchos` | Sigue el patrón ya usado en `dbt_project.yml` (`+schema: staging`, `+schema: marts`) — solo lo extiende a L0 (hoy sin dataset propio, es literalmente `ranchos`) y a L4/metadatos, que no existen todavía. Alternativa: un solo prefijo común `dw_` (`dw_staging`, `dw_marts`) en vez de `ranchos` — se descarta porque este proyecto YA se llama `ranchos-dw`/`ranchos_dw` a nivel de repo/profile, agregar otro prefijo sería redundante. |

---

## Estado de este informe

Cumple el entregable de Fase 0 pedido por el documento. **No se creó
ningún modelo, tabla ni cambio de infraestructura durante esta fase** —
solo lectura. Punto de control 1: pendiente de tu aprobación antes de
crear cualquier archivo de la Fase 2 en adelante.
