-- Grano: una muestra de composición (grasa/proteína/lactosa/ST/SNG/células somáticas).
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_muestra', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['id_finca']
    )
}}
select
    id_registro,
    fecha_muestra,
    id_finca,
    composicion_grasa,
    composicion_proteina,
    composicion_lactosa,
    composicion_st,
    composicion_sng,
    celulas_somaticas,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__composicion_leche') }}
