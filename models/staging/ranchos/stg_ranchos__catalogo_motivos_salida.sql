-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). PK real de esta
-- tabla es id_motivo, no id_item (única excepción de nomenclatura entre
-- los catálogos de Hato — ver docs/fase0_inspeccion.md).
with source as (

    select * from {{ source('ranchos', 'tb_dim_catalogo_motivos_salida') }}

),

renamed as (

    select
        id_motivo,
        nombre,
        estado,
        finca_asociada,
        fecha_creacion

    from source
    where {{ filtro_finca_prueba_por_nombre() }}

)

select * from renamed
