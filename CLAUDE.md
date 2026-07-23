# RanchOS DW — Contexto del Proyecto

## Qué es esto
`ranchos-dw` es el **Data Warehouse analítico** de RanchOS, separado a
propósito de la app operacional. Transforma (vía dbt) los datos que la app
operacional ya sincroniza a BigQuery — este proyecto no captura datos por sí
mismo, solo los modela para reporting/analítica.

- **App operacional** (Firestore, Firebase Auth, Hosting, Cloud Functions que
  hacen el sync a BigQuery): repo `ranchos--app`
  (`C:\ALBA_ANALYTICS\GANADERIA\ranchos--app`), proyecto GCP `ranchos-7c313`.
  Producción: https://ranchos-7c313.web.app/
- **Data Warehouse analítico** (este repo): proyecto GCP
  `alba-analytics-ganaderia`.
- **Por qué están separados:** aislar costos/IAM/blast-radius entre lo
  operacional (app en vivo, usada por colaboradores de campo) y lo analítico
  (transformaciones, reporting, futuros dashboards) — que un cambio de
  modelado en el DW nunca pueda afectar la app en producción, y viceversa.
- Desarrollado y mantenido por la misma persona que `ranchos--app`
  (desarrollador con background de Ingeniería de Datos / Data Warehouse,
  aprendiendo dbt/analytics engineering sobre la marcha en este proyecto).

**Memoria de Claude Code separada a propósito:** este directorio tiene su
propio scope de memoria persistente, distinto del de `ranchos--app` — las
decisiones de arquitectura del DW no se mezclan con el historial de PRs de
la app operacional, y viceversa. Si necesitás contexto de cómo funciona la
app operacional (esquema de Firestore, qué Cloud Function sincroniza qué
tabla, etc.), consultá `CLAUDE.md` de `ranchos--app` — no lo dupliques acá.

## Stack
- **Transformación:** dbt-core 1.12.0 + adaptador dbt-bigquery 1.12.0.
- **Entorno Python:** venv dedicado en `.venv/` (nunca usar una instalación
  global de dbt) — `pip install -r requirements.txt` para recrearlo.
- **Conexión a BigQuery:** `~/.dbt/profiles.yml` (fuera del repo, no
  versionado), `method: oauth` vía Application Default Credentials
  (`gcloud auth application-default login`) — nunca un archivo de service
  account key en texto plano, mismo criterio de seguridad que
  `ranchos--app`.
- **Linting SQL:** sqlfluff, dialecto `bigquery`, config en `.sqlfluff`.
- **Editor:** VSCode, abrir la carpeta `dw_ranchos_app` como workspace raíz
  (no el repo completo de `ranchos--app`) para que la extensión de dbt
  detecte `dbt_project.yml`. Extensiones recomendadas ya declaradas en
  `.vscode/extensions.json`.
- **Repo:** https://github.com/josealba507/ranchos-dw (privado).

## Arquitectura de capas
```
sources (BigQuery: tb_dim_*, tb_fact_* — dataset "ranchos")
    │
    ▼
staging/<fuente>/    stg_*   1:1 con la fuente, solo renombra/castea tipos.
                             Vista. Nunca hace joins ni agregaciones.
    │
    ▼
intermediate/        int_*   joins/agregaciones reutilizables. Ephemeral —
                             no persiste como tabla en BigQuery.
    │
    ▼
marts/<dominio>/     dim_*/fct_*  modelos finales, tabla. Organizados por
                             DOMINIO de negocio (finanzas/leche/hato/
                             veterinaria), no por tabla fuente. Es lo único
                             que BI/reporting debe consultar.
```

Reglas completas de gobernanza de datos (DAMA-DMBOK traducido a reglas
concretas de dbt — tests obligatorios por capa, naming, versionado
histórico, metadata, PII, lineage) en
[`docs/dama_governance.md`](docs/dama_governance.md). No repetir esas
reglas acá — ese documento es la fuente de verdad, este `CLAUDE.md` es
contexto de proyecto.

## Separación de entornos (dev/prod)
`macros/generate_schema_name.sql` antepone `dev_` a cada dataset cuando el
target es `dev` (el default en `profiles.yml` para trabajo local) — un
`dbt run` local nunca escribe sobre los datasets "reales" que algún día
consuma un dashboard. El target `prod` (`dbt run -t prod`) escribe sin
prefijo, reservado para cuando exista un pipeline/CI real.

## Versionado histórico — regla heredada de la app operacional
Las fact tables de `ranchos--app` **nunca hacen UPDATE in-place**: al
corregir un registro, la fila vigente pasa a `estado_registro='Corregido'`/
`'Anulado'` y se inserta una fila nueva `'Activo'` (SCD tipo 2 a nivel de
fila individual). **Todo modelo de `staging/` sobre una fact table debe
filtrar** `WHERE estado_registro = '{{ var("estado_registro_vigente") }}'`
(var ya definida en `dbt_project.yml`, valor `'Activo'`) — nunca hardcodear
el string suelto en el SQL. Si un modelo necesita el histórico completo
(auditoría, no reporting), debe nombrarse explícitamente
`int_<entidad>_historico_completo` y documentar por qué.

## Estado actual del proyecto
- **Scaffolding completo y verificado** (`dbt debug` conecta OK contra
  `alba-analytics-ganaderia`, `dbt parse` compila sin errores/warnings,
  `sqlfluff lint` limpio): estructura de carpetas, `dbt_project.yml`,
  `packages.yml` (`dbt_utils` + `dbt_expectations`), `.sqlfluff`, VSCode,
  modelo de referencia `stg_ranchos__animales` con el nivel mínimo de
  tests DAMA exigido (ver `docs/dama_governance.md` sección 1), `git init`
  + primer commit + repo en GitHub.
- **Migración histórica completa — hecha (2026-07-21).** Decisión
  confirmada con el usuario: `ranchos-7c313` sigue siendo la fuente
  operacional intocada (las Cloud Functions de `ranchos--app` NO se
  tocaron, ni su destino de sync ni ningún deploy); `alba-analytics-
  ganaderia` es una RÉPLICA analítica separada. Dataset `ranchos` creado
  (ubicación `US`, igual que el origen) y las 19 tablas
  (`tb_dim_*`/`tb_fact_*`) copiadas tabla por tabla vía `bq cp -f --sync`
  cross-project — conteos de filas verificados idénticos en ambos lados
  tras la copia (ej. `tb_fact_transacciones_financieras` 1151/1151,
  `tb_dim_animales` 170/170).
- **Hallazgo antes de migrar — dataset `Ganaderia` no documentado, ya
  eliminado:** `alba-analytics-ganaderia` NO estaba vacío como asumía
  este archivo — tenía un dataset `Ganaderia` (mayúscula, distinto de
  `ranchos`) con una tabla `tb_fact_transacciones_financieras_old` (1103
  filas, coincidente con el backfill de Finanzas de Alba Guerra) y una
  tabla externa `tb_stg_transacciones_sheets`, sin relación con este
  proyecto ni documentado en ningún CLAUDE.md. Confirmado con el usuario
  que era una prueba vieja — se borró por completo
  (`bq rm -r -f -d alba-analytics-ganaderia:Ganaderia`) antes de crear el
  dataset `ranchos` real, para no dejar basura de datos en el proyecto
  del DW.
- **2 discrepancias de esquema encontradas y corregidas al conectar por
  primera vez contra datos reales** (el modelo de referencia y
  `sources.yml` se habían escrito en base a lo documentado en
  `ranchos--app/CLAUDE.md`, no contra el esquema real verificado):
  1. `tb_dim_animales` NO tiene columna `foto_url` — el `ALTER TABLE`
     que el CLAUDE.md de `ranchos--app` documenta (PR #84) nunca se
     ejecutó en producción (confirmado además que
     `functions/src/index.ts` no referencia `foto_url` en ningún lado —
     no es un bug activo de sync, solo documentación desactualizada de
     ese repo, sin código nuevo esperando esa columna). Se quitó del
     `select` de `stg_ranchos__animales.sql`.
     **Resuelto en `ranchos--app` el 2026-07-23** (PR #109 de ese repo):
     `ALTER TABLE` + código de sync + backfill de los 84 animales con
     foto ya cargados, todo verificado en producción real (ver
     `ranchos--app/CLAUDE.md`). Este repo se puso al día el mismo día:
     `tb_dim_animales` se volvió a copiar completa
     (`bq cp -f --sync ranchos-7c313:ranchos.tb_dim_animales
     alba-analytics-ganaderia:ranchos.tb_dim_animales`, mismo método que
     la migración histórica original) — 170/170 filas, 84/84 con
     `foto_url`, verificado en ambos lados. `foto_url` volvió al
     `select` de `stg_ranchos__animales.sql` y a su documentación en
     `_ranchos__models.yml`; `dbt run` + `dbt test` (6/6) confirmados
     limpios contra la réplica actualizada.
  2. **Patrón de nombre de columna real, no `timestamp_registro` en
     todos lados:** las tablas DIM usan `fecha_creacion` (DATE); las
     FACT usan `timestamp_registro` (TIMESTAMP) — EXCEPTO
     `tb_fact_logs_actividad`, que usa `timestamp_evento`, y
     `tb_dim_fincas`, que usa `fecha_registro`. `sources.yml` tenía
     `loaded_at_field: timestamp_registro` mal puesto en `tb_dim_animales`
     (dim, no fact) — corregido a `fecha_creacion` — y en
     `tb_fact_logs_actividad` — corregido a `timestamp_evento`.
     Verificado con una query a
     `INFORMATION_SCHEMA.COLUMNS` contra las 19 tablas reales, no solo
     inferido. `stg_ranchos__animales.sql` y sus 6 tests DAMA corren y
     pasan contra los datos migrados reales (`dbt run` + `dbt test`
     limpios).
- **Pendiente — actualización continua de la réplica (EL), no resuelto
  todavía:** la copia de arriba es un snapshot único (histórico completo
  al 2026-07-21). Falta decidir e implementar cómo la réplica
  `alba-analytics-ganaderia:ranchos` se mantiene al día con
  `ranchos-7c313:ranchos` hacia adelante (opciones a evaluar: BigQuery
  Data Transfer Service con "cross-project dataset copy" programado —
  nativo, sin código propio, probablemente la opción de menor
  mantenimiento para un solo desarrollador —, vs. un job propio
  programado vía Cloud Scheduler + `bq cp`/`bq query`). Como las fact
  tables versionan filas existentes (`estado_registro`: Activo→Corregido)
  en vez de solo agregar filas nuevas, cualquier estrategia incremental
  por "solo filas nuevas" perdería esas correcciones — la réplica
  necesita poder reflejar cambios de estado en filas ya existentes, no
  solo altas.
- **Ningún modelo de `marts/` existe todavía** — las carpetas
  `marts/finanzas`, `marts/leche`, `marts/hato`, `marts/veterinaria` están
  vacías (solo `.gitkeep`/config en `dbt_project.yml`). Ya no hay
  bloqueante técnico para empezar (los datos reales ya están accesibles),
  solo falta decidir la estrategia de actualización continua de arriba
  antes de construir sobre datos que quedarían desactualizados sin
  aviso.

## Prioridades actuales (en orden)
1. ~~Resolver la migración de datos~~ — **hecho** (histórico completo
   migrado 2026-07-21, ver "Estado actual" arriba). Sigue pendiente la
   sub-parte de actualización continua (EL hacia adelante) — ver mismo
   punto de "Estado actual".
2. Construir la capa `staging/` completa (las 19 tablas de
   `sources.yml`, hoy solo hay 1 modelo de referencia) con sus tests
   mínimos DAMA — ya se puede correr y verificar contra datos reales.
3. Primeros marts por dominio — probablemente `marts/finanzas` y
   `marts/leche` primero, por ser los dominios con más historia de datos
   ya cargada en el proyecto operacional (backfills de Ganadera Alba
   Guerra, ver `ranchos--app/CLAUDE.md`).
4. `dbt docs generate` + `dbt docs serve` como catálogo de datos navegable,
   una vez haya suficientes modelos para que valga la pena.
5. Evaluar automatizar `dbt run`/`dbt test` (Cloud Build, GitHub Actions,
   o un scheduler simple) en vez de correrlo siempre a mano desde local —
   todavía sin decidir, no hay urgencia mientras el proyecto sea de un solo
   desarrollador. Probablemente se resuelve junto con la decisión de
   actualización continua de la réplica (ítem 1) si se elige un job
   propio en vez de BigQuery Data Transfer Service nativo.

## Cómo trabajar conmigo en este proyecto
Mismo criterio de colaboración que ya está establecido en `ranchos--app`
(mismo desarrollador, mismo estilo de trabajo):
- Soy el único desarrollador. Explicá el *por qué* de cada cambio, no solo
  el qué — estoy aprendiendo dbt/analytics engineering sobre la marcha, mi
  fuerte es datos pero no necesariamente las convenciones específicas del
  ecosistema dbt.
- Antes de tocar cualquier cosa que cruce a `ranchos--app` (permisos IAM,
  `functions/src/index.ts`, deploys de esa app) o que sea un
  DROP/ALTER/migración destructiva sobre `alba-analytics-ganaderia`,
  mostrame el cambio y esperá confirmación explícita — mismo nivel de
  cautela que ya rige en `ranchos--app` para producción.
- Commits pequeños y descriptivos. No mezclar refactors grandes con fixes.
- Nunca subir ni imprimir claves de servicio, API keys, ni archivos
  `.env`/`serviceAccountKey.json` — verificar que estén en `.gitignore`
  (ya cubierto, pero revalidar si se agrega algo nuevo que las use).
- Antes de crear un mart o modelo nuevo, aplicar como mínimo los 3 tests
  de `docs/dama_governance.md` sección 1 (`unique`+`not_null` en PK,
  `relationships` en cada FK) — no es opcional, es la regla dura del
  proyecto.
- Todo modelo debe usar `{{ ref(...) }}`/`{{ source(...) }}`, nunca un
  nombre de tabla crudo en un `FROM` — es lo que mantiene el grafo de
  lineage (`dbt docs generate`) confiable.

## Pendiente de definir (preguntar si hace falta)
- **Estrategia de actualización continua de la réplica** (EL hacia
  adelante, ver "Estado actual" arriba) — ahora la decisión más urgente
  del proyecto, reemplaza a la migración histórica (ya resuelta).
- Herramienta de BI/reporting final (Looker Studio es la opción más
  natural por ser gratis y de Google, pero no está decidido) — recién
  relevante una vez existan marts reales para conectar.
- Si el proyecto va a necesitar CI/CD propio (GitHub Actions corriendo
  `dbt build` en cada PR) o si alcanza con correrlo a mano por ahora,
  dado que es un solo desarrollador.
