-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). Sin
-- estado_registro (dimensión, no fact) — no aplica el filtro de vigencia
-- de la sección 3.
with source as (

    select * from {{ source('ranchos', 'tb_dim_catalogo_finanzas') }}

),

renamed as (

    select
        id_item,
        tipo_transaccion,
        categoria,
        clase_gasto,
        estado,
        finca_asociada,
        fecha_creacion

    from source
    -- Ver macros/filtros_datos_prueba.sql. Sin filas TEST- confirmadas acá
    -- (ver docs/fase0_inspeccion.md), pero se aplica igual por consistencia
    -- con el resto de los modelos de staging de este proyecto.
    where {{ filtro_finca_prueba_por_nombre() }}

)

select * from renamed
