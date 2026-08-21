-- Grano: un movimiento financiero (Entrada/Inversion/Salida).
--
-- id_usuario se conserva como dimensión degenerada, mismo criterio que
-- fct_movimiento_insumo (sin dim_usuario propia todavía, ver
-- docs/checkpoint2_movimientos_insumos.md). monto_total es NUMERIC, no
-- centavos enteros — decisión ya tomada por el proyecto operacional (ver
-- docs/fase0_inspeccion.md, inconsistencia 1).
--
-- Referencia dim_finca por id_finca, no finca_asociada — esta fact table
-- es la excepción de nomenclatura del proyecto (ver
-- docs/fase0_inspeccion.md).
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_transaccion', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['id_finca']
    )
}}
select
    id_registro,
    fecha_transaccion,
    id_finca,
    tipo_transaccion,
    categoria,
    clase,
    proveedor_tercero,
    detalle_movimiento,
    monto_total,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__transacciones_financieras') }}
