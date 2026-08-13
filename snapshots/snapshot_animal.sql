-- Historización SCD tipo 2 del inventario de animales (L2 — Integración,
-- ver docs/dama_governance.md sección 2). Fase 4 del documento de
-- especificación, textual: "Animal — cambia de lote, categoría y estado a
-- lo largo de su vida" — sin esto, un reporte histórico mostraría siempre
-- el lote/categoría/estado ACTUAL de un animal, aunque el evento haya
-- ocurrido cuando tenía otro.
--
-- Estrategia "check", no "timestamp" — mismo motivo que snapshot_insumo.sql
-- (sin campo confiable de última actualización, ver
-- docs/fase0_inspeccion.md sección 0.3).
--
-- arete/chip/foto_url quedan afuera de check_cols a propósito: cambian
-- (ej. aretar un animal después) pero no son los 3 atributos que Fase 4
-- pide historizar — versionarlos infla el número de filas del snapshot
-- sin agregar valor analítico (nadie necesita saber "qué arete tenía este
-- animal el mes pasado").
{% snapshot snapshot_animal %}

{{
    config(
      unique_key='id_animal',
      strategy='check',
      check_cols=['lote', 'categoria_animal', 'estado'],
    )
}}

    select * from {{ ref('stg_ranchos__animales') }}

{% endsnapshot %}
