-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). Cualquier lógica
-- de negocio (ej. agrupar pesajes por día) vive en intermediate/, no acá.
with source as (

    select * from {{ source('ranchos', 'tb_dim_animales') }}

),

renamed as (

    select
        id_animal,
        arete,
        chip,
        sexo,
        estado,
        finca_asociada,
        cast(fecha_nacimiento as date) as fecha_nacimiento,
        id_madre,
        id_padre,
        padre_tipo,
        fecha_creacion,
        foto_url

    from source

)

select * from renamed
