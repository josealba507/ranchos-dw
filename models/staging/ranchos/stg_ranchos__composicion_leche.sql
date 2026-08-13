-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Filtro de vigencia obligatorio (sección 3): fila 'Activo' es la vigente.
-- Referencia la finca por id_finca, no finca_asociada.
with source as (

    select * from {{ source('ranchos', 'tb_fact_composicion_leche') }}

),

renamed as (

    select
        id_registro,
        fecha_muestra,
        id_finca,
        composicion_grasa,
        composicion_proteina,
        composicion_lactosa,
        composicion_st,
        composicion_sng,
        celulas_somaticas,
        id_usuario,
        canal_captura,
        estado_registro,
        id_registro_correccion,
        timestamp_registro

    from source
    where estado_registro = '{{ var("estado_registro_vigente") }}'
    -- Ver macros/filtros_datos_prueba.sql.
    and {{ filtro_finca_prueba_por_id() }}

)

select * from renamed
