-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2).
--
-- Filtro de vigencia obligatorio (sección 3): fila 'Activo' es la vigente.
-- Referencia la finca por id_finca, no finca_asociada (mismo patrón que
-- Finanzas, ver docs/fase0_inspeccion.md).
--
-- Los 5 valores derivados (litros_valor_base...valor_litro_total) NUNCA
-- se recalculan acá — son la fuente de verdad server-side de
-- calcularEntregaLeche/corregirEntregaLeche (Cloud Functions callable, ver
-- CLAUDE.md de ranchos--app) — este passthrough los conserva tal cual
-- llegan, no los re-deriva de litros_entrega.
with source as (

    select * from {{ source('ranchos', 'tb_fact_venta_leche') }}

),

renamed as (

    select
        id_registro,
        fecha_pago,
        id_finca,
        litros_entrega,
        litros_valor_base,
        incentivo_valor,
        valor_entrega_bruta,
        multa,
        valor_entrega_neta,
        valor_litro_base,
        valor_litro_incentivo,
        valor_litro_total,
        id_usuario,
        nombre_usuario,
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
