-- Grano: un pesaje por animal por ordeño (Mañana/Tarde) — distinto (más
-- fino) que fct_venta_leche, que es a nivel finca (ver
-- stg_ranchos__pesaje_leche.sql).
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_pesaje', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['finca_asociada', 'id_animal']
    )
}}
select
    id_registro,
    fecha_pesaje,
    ordeno,
    id_animal,
    arete_animal,
    litros,
    finca_asociada,
    id_finca,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__pesaje_leche') }}
