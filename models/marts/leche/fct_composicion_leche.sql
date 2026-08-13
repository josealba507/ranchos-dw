-- Grano: una muestra de composición (grasa/proteína/lactosa/ST/SNG/células somáticas).
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
