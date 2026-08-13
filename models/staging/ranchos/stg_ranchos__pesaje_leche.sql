-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). Grano de este
-- pesaje es POR ANIMAL POR ORDEÑO — distinto (y más fino) que
-- tb_fact_venta_leche (a nivel finca), ver CLAUDE.md de ranchos--app:
-- "Pesaje de Leche... nombres deliberadamente distintos en toda la UI/DB
-- para no confundir los dos grano de datos".
--
-- Filtro de vigencia obligatorio (sección 3): fila 'Activo' es la vigente.
--
-- ordeno normalizado vía macros/normalizar_mojibake.sql: 53 de 128 filas
-- reales llegan con UTF-8 mal re-codificado ("MaÃ±ana" en vez de
-- "Mañana") — mismo hallazgo que en stg_ranchos__palpamientos.sql.
with source as (

    select * from {{ source('ranchos', 'tb_fact_pesaje_leche') }}

),

renamed as (

    select
        id_registro,
        fecha_pesaje,
        {{ normalizar_mojibake('ordeno') }} as ordeno,
        id_animal,
        arete_animal,
        litros,
        finca_asociada,
        id_finca,
        id_usuario,
        canal_captura,
        estado_registro,
        id_registro_correccion,
        timestamp_registro

    from source
    where
        estado_registro = '{{ var("estado_registro_vigente") }}'
        and {{ filtro_finca_prueba_por_nombre() }}

)

select * from renamed
