-- Grano: una muestra de microbiología (UFC/ml).
select
    id_registro,
    fecha_muestra,
    id_finca,
    microbiologia_muestra,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__microbiologia_leche') }}
