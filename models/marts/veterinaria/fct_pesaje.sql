-- Grano: un pesaje por animal por ordeño (Mañana/Tarde) — distinto (más
-- fino) que fct_venta_leche, que es a nivel finca (ver
-- stg_ranchos__pesaje_leche.sql).
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
