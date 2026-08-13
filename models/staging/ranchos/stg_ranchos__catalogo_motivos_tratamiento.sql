-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). Solo alta
-- automática en producción (sin edición/borrado) — sin historización SCD2.
with source as (

    select * from {{ source('ranchos', 'tb_dim_catalogo_motivos_tratamiento') }}

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
