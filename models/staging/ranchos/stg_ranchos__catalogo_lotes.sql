-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). Sin
-- estado_registro (dimensión, no fact).
--
-- nombre/estado son mutables — historización SCD2 en
-- snapshots/snapshot_lote.sql, no acá (Fase 4 del documento de
-- especificación: "Lote / hato" cambia y necesita seguimiento de cambios).
with source as (

    select * from {{ source('ranchos', 'tb_dim_catalogo_lotes') }}

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
