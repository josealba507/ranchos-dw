-- Grano: una entrega/venta de leche.
--
-- Los 5 valores derivados se conservan tal cual llegan de staging — son
-- fuente de verdad server-side (ver stg_ranchos__venta_leche.sql). id_usuario
-- y nombre_usuario quedan como dimensión degenerada, mismo criterio que el
-- resto de los hechos de este proyecto (sin dim_usuario propia todavía).
select
    id_registro,
    fecha_pago,
    id_finca,
    litros_entrega,
    litros_valor_base,
    incentivo_valor,
    valor_entrega_bruta,
    multa,
    valor_entrega_neta,
    valor_litro_base,
    valor_litro_incentivo,
    valor_litro_total,
    id_usuario,
    nombre_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__venta_leche') }}
