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
- **`sources.yml` declara las 19 tablas fuente reales** (`tb_dim_*`/
  `tb_fact_*`) del dataset `ranchos`, pero **ese dataset todavía NO existe
  en `alba-analytics-ganaderia`** — hoy vive únicamente en `ranchos-7c313`
  (el proyecto operacional). `dbt run`/`dbt source freshness` van a fallar
  contra sources reales hasta resolver la migración.
- **Pendiente crítico, bloquea todo trabajo real de modelado:** decidir e
  implementar la estrategia de migración de datos hacia
  `alba-analytics-ganaderia`. Dos sub-decisiones:
  1. ¿Migrar el histórico completo ya cargado en `ranchos-7c313`, o
     arrancar el DW nuevo vacío y alimentarlo solo hacia adelante?
  2. Esto requiere: dar permisos IAM cross-project (`bigquery.dataEditor`)
     a la service account de Cloud Functions de `ranchos-7c313` sobre
     `alba-analytics-ganaderia`, modificar `functions/src/index.ts` (repo
     `ranchos--app`) para apuntar el cliente de `@google-cloud/bigquery`
     al proyecto nuevo, y un deploy a producción de esa app — **tocar eso
     requiere cruzar a la sesión de `ranchos--app` y confirmación
     explícita del usuario antes de ejecutar**, mismo criterio de cautela
     que ya rige ese repo para cambios de producción.
- **Ningún modelo de `marts/` existe todavía** — las carpetas
  `marts/finanzas`, `marts/leche`, `marts/hato`, `marts/veterinaria` están
  vacías (solo `.gitkeep`/config en `dbt_project.yml`). El primer trabajo
  real de modelado empieza recién cuando el dataset fuente exista en el
  proyecto nuevo.

## Prioridades actuales (en orden)
1. **Resolver la migración de datos** (ver "Estado actual" arriba) — es lo
   único que bloquea poder correr `dbt run`/`dbt test` contra datos reales.
2. Una vez resuelto: construir la capa `staging/` completa (las 19 tablas
   de `sources.yml`, hoy solo hay 1 modelo de referencia) con sus tests
   mínimos DAMA.
3. Primeros marts por dominio — probablemente `marts/finanzas` y
   `marts/leche` primero, por ser los dominios con más historia de datos
   ya cargada en el proyecto operacional (backfills de Ganadera Alba
   Guerra, ver `ranchos--app/CLAUDE.md`).
4. `dbt docs generate` + `dbt docs serve` como catálogo de datos navegable,
   una vez haya suficientes modelos para que valga la pena.
5. Evaluar automatizar `dbt run`/`dbt test` (Cloud Build, GitHub Actions,
   o un scheduler simple) en vez de correrlo siempre a mano desde local —
   todavía sin decidir, no hay urgencia mientras el proyecto sea de un solo
   desarrollador.

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
- Estrategia de migración de datos históricos (ver "Estado actual" y
  "Prioridades actuales" arriba) — la decisión más urgente del proyecto.
- Herramienta de BI/reporting final (Looker Studio es la opción más
  natural por ser gratis y de Google, pero no está decidido) — recién
  relevante una vez existan marts reales para conectar.
- Si el proyecto va a necesitar CI/CD propio (GitHub Actions corriendo
  `dbt build` en cada PR) o si alcanza con correrlo a mano por ahora,
  dado que es un solo desarrollador.
