-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Filtro de vigencia obligatorio (sección 3): fila 'Activo' es la vigente.
with source as (

    select * from {{ source('ranchos', 'tb_fact_partos') }}

),

renamed as (

    select
        id_registro,
        fecha_parto,
        id_madre,
        arete_madre,
        sexo_cria,
        arete_cria,
        chip_cria,
        observaciones,
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
