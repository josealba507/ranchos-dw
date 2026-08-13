-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Es una dimensión (no fact) — sin estado_registro/versionado por fila,
-- así que no aplica el filtro de vigencia de la sección 3 de
-- docs/dama_governance.md. La historización de categoria/presentacion/
-- estado se resuelve con un snapshot (ver snapshots/snapshot_insumo.sql),
-- no acá.
with source as (

    select * from {{ source('ranchos', 'tb_dim_catalogo_insumos') }}

),

renamed as (

    select
        id_insumo,
        nombre,
        categoria,
        unidad_base,
        maneja_vencimiento,
        existencia_actual,
        estado,
        presentacion,
        finca_asociada,
        fecha_creacion

    from source
    -- Excluye residuos de sesiones de verificación de ranchos--app: fincas
    -- de prueba con prefijo TEST- que nunca se limpiaron del todo en
    -- producción (ver docs/fase0_inspeccion.md — "Debug Insumo"/
    -- "Alimento Vacas Ordeño (TEST)" ya estaban documentados como
    -- huérfanos conocidos en CLAUDE.md de ranchos--app; acá se encontraron
    -- más). No es lógica de negocio real — es sanear basura técnica antes
    -- de que rompa el test de integridad referencial contra tb_dim_fincas.
    where finca_asociada not like 'TEST-%'

)

select * from renamed
