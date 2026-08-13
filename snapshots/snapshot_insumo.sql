-- Historización SCD tipo 2 del catálogo de insumos (L2 — Integración, ver
-- docs/dama_governance.md sección 2 y docs/fase2_arquitectura.md). Insumo
-- cambia de categoria/presentacion/estado a lo largo de su vida — sin esto,
-- un reporte histórico mostraría siempre la categoría ACTUAL de un insumo,
-- aunque el movimiento haya ocurrido cuando tenía otra.
--
-- Estrategia "check", no "timestamp": la fuente no tiene un campo confiable
-- de última actualización (ver docs/fase0_inspeccion.md, sección 0.3 — no
-- hay serverTimestamp(), y fecha_creacion es fija desde el alta, no se
-- actualiza en cada edición). "check" compara los valores de check_cols en
-- cada corrida de `dbt snapshot` contra la última versión guardada.
--
-- unidad_base queda afuera de check_cols a propósito: es inmutable después
-- de creado (firestore.rules lo exige, ver CLAUDE.md de ranchos--app) — no
-- tiene sentido versionar una columna que nunca cambia.
--
-- Snapshotea sobre stg_ranchos__catalogo_insumos (staging), no sobre el
-- source crudo, para heredar el filtro de datos de prueba (fincas TEST-*,
-- ver comentario en ese modelo) sin duplicar esa regla acá.
{% snapshot snapshot_insumo %}

{{
    config(
      unique_key='id_insumo',
      strategy='check',
      check_cols=['categoria', 'presentacion', 'estado'],
    )
}}

    select * from {{ ref('stg_ranchos__catalogo_insumos') }}

{% endsnapshot %}
