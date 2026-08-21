-- Grano: una entrega/venta de leche.
--
-- Los 5 valores derivados se conservan tal cual llegan de staging — son
-- fuente de verdad server-side (ver stg_ranchos__venta_leche.sql). id_usuario
-- y nombre_usuario quedan como dimensión degenerada, mismo criterio que el
-- resto de los hechos de este proyecto (sin dim_usuario propia todavía).
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_pago', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['id_finca']
    )
}}
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
