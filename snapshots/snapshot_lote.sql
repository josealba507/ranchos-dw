-- Historización SCD tipo 2 del catálogo de lotes de manejo (L2 —
-- Integración). Fase 4 del documento de especificación, textual:
-- "Lote / hato — usa el nombre que ya exista en el proyecto" dentro de la
-- lista de dimensiones que necesitan seguimiento de cambios.
--
-- Estrategia "check" — mismo motivo que snapshot_insumo.sql/
-- snapshot_animal.sql.
{% snapshot snapshot_lote %}

{{
    config(
      unique_key='id_item',
      strategy='check',
      check_cols=['nombre', 'estado'],
    )
}}

    select * from {{ ref('stg_ranchos__catalogo_lotes') }}

{% endsnapshot %}
