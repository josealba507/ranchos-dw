-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Filtro de vigencia obligatorio (docs/dama_governance.md sección 3): esta
-- fact table versiona correcciones (estado_registro: Activo/Corregido/
-- Anulado) en vez de hacer UPDATE in-place — solo la fila 'Activo' es la
-- vigente.
--
-- A diferencia de Hato/Veterinaria/Insumos, esta tabla NO tiene columna
-- finca_asociada — referencia la finca por id_finca directo (ver
-- docs/fase0_inspeccion.md, inconsistencia de nombres de columna entre
-- tablas). El filtro de datos de prueba usa el macro correspondiente a
-- esa columna.
with source as (

    select * from {{ source('ranchos', 'tb_fact_transacciones_financieras') }}

),

renamed as (

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
        estado_registro,
        id_registro_correccion,
        timestamp_registro

    from source
    where estado_registro = '{{ var("estado_registro_vigente") }}'
    -- Ver macros/filtros_datos_prueba.sql.
    and {{ filtro_finca_prueba_por_id() }}

)

select * from renamed
