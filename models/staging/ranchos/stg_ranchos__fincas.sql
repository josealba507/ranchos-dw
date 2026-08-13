-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
with source as (

    select * from {{ source('ranchos', 'tb_dim_fincas') }}

),

renamed as (

    select
        id_finca,
        nombre_finca,
        ubicacion,
        estado,
        fecha_registro

    from source

)

select * from renamed
