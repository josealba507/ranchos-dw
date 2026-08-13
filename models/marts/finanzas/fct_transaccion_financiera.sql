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
