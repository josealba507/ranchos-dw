-- Grano: un nacimiento.
--
-- id_madre referencia dim_animal.id_animal (no único ahí — SCD2, ver
-- dim_animal.sql). Sin enriquecimiento punto-en-el-tiempo del lote/
-- categoría de la madre al momento del parto — a diferencia de
-- fct_movimiento_insumo (Punto de Control 2), acá no hay un caso de
-- negocio que lo requiera todavía; se deja como posible extensión futura,
-- documentado en docs/dominio_hato.md, no construido especulativamente.
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_parto', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['finca_asociada', 'id_madre']
    )
}}
select
    id_registro,
    fecha_parto,
    id_madre,
    arete_madre,
    sexo_cria,
    arete_cria,
    chip_cria,
    observaciones,
    finca_asociada,
    id_finca,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__partos') }}
