-- Passthrough 1:1 con la fuente: renombra/castea, nunca hace joins ni
-- agregaciones (ver docs/dama_governance.md, sección 2). La lógica de
-- negocio (resolver la versión histórica correcta del insumo al momento
-- del movimiento) vive en intermediate/, no acá.
--
-- Filtro de vigencia obligatorio (docs/dama_governance.md sección 3): esta
-- fact table versiona correcciones (estado_registro: Activo/Corregido/
-- Anulado) en vez de hacer UPDATE in-place — solo la fila 'Activo' es la
-- vigente.
with source as (

    select * from {{ source('ranchos', 'tb_fact_movimientos_insumos') }}

),

renamed as (

    select
        id_registro,
        id_insumo,
        tipo_movimiento,
        fecha_movimiento,
        cantidad_base,
        cantidad_capturada,
        id_presentacion,
        -- Vestigial desde PR #142/#137 de ranchos--app (ver
        -- docs/fase0_inspeccion.md, hallazgo 4): siempre vale 1 en
        -- movimientos capturados después de ese cambio. Se conserva la
        -- columna para no perder el histórico de movimientos previos que
        -- sí tenían un factor real, no porque siga siendo un dato vivo.
        factor_presentacion_copiado,
        costo_total,
        proveedor,
        numero_lote,
        fecha_vencimiento,
        motivo,
        id_movimiento_compensado,
        id_periodo_generado,
        finca_asociada,
        id_finca,
        id_usuario,
        canal_captura,
        estado_registro,
        id_registro_correccion,
        timestamp_registro

    from source
    where estado_registro = '{{ var("estado_registro_vigente") }}'
    -- Excluye residuos de sesiones de verificación de ranchos--app
    -- (fincas de prueba con prefijo TEST-, nunca limpiadas del todo en
    -- producción — ver docs/fase0_inspeccion.md y el comentario
    -- equivalente en stg_ranchos__catalogo_insumos.sql). No es lógica
    -- de negocio real.
    and finca_asociada not like 'TEST-%'

)

select * from renamed
