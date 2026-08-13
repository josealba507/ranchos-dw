-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Sin historización SCD2 (a diferencia de lote/animal) — el documento de
-- especificación no la lista explícitamente para "categoría", y a
-- diferencia de lote no tiene un caso de negocio documentado que la
-- requiera (ver docs/dominio_hato.md).
with source as (

    select * from {{ source('ranchos', 'tb_dim_catalogo_categorias_animal') }}

),

renamed as (

    select
        id_item,
        nombre,
        estado,
        finca_asociada,
        fecha_creacion

    from source
    where {{ filtro_finca_prueba_por_nombre() }}

)

select * from renamed
