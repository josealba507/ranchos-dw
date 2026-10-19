-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Filtro de vigencia obligatorio (sección 3): fila 'Activo' es la vigente.
-- fecha_parto_esperada NO se recalcula acá — es un estimado 100%
-- client-side en ranchos--app (283 − días de gestación), sin
-- sensibilidad financiera (ver CLAUDE.md de ese repo), se conserva tal
-- cual llega.
--
-- resultado pasa tal cual llega. Hasta octubre de 2026 se normalizaba acá
-- el UTF-8 mal re-codificado ("PreÃ±ada" en vez de "Preñada") con una
-- macro; ese texto se corrigió en el origen (ranchos-7c313, ver "Reparación
-- del DW" en el CLAUDE.md de ranchos--app) y la macro se eliminó.
with source as (

    select * from {{ source('ranchos', 'tb_fact_palpamientos') }}

),

renamed as (

    select
        id_registro,
        fecha_palpamiento,
        id_animal,
        arete_animal,
        resultado,
        dias_gestacion,
        fecha_parto_esperada,
        estado_gestacion,
        meses_atraso,
        veterinario,
        comentario,
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
