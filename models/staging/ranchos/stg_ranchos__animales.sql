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
        foto_url,
        -- Cambian a lo largo de la vida del animal — su historización SCD2
        -- vive en snapshots/snapshot_animal.sql (ver docs/dominio_hato.md),
        -- no acá.
        lote,
        categoria_animal

    from source
    -- Ver macros/filtros_datos_prueba.sql.
    where {{ filtro_finca_prueba_por_nombre() }}

)

select * from renamed
