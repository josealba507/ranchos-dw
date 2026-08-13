-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5): lo único
-- que BI/Looker Studio debe consultar para este dominio, no marts_ranchos
-- directo. Sin control de acceso por columna todavía (policy tags sobre
-- costo_total quedan para la Fase 8 del documento de especificación,
-- fuera de alcance del Punto de Control 2).
--
-- No vuelve a resolver la categoría/unidad del insumo con un join propio
-- — ya vienen denormalizadas "al momento del movimiento" desde
-- fct_movimiento_insumo (ver models/intermediate/int_movimientos_insumos_con_insumo_historico.sql),
-- que es justo el problema que la historización SCD2 de dim_insumo existe
-- para resolver una sola vez, no en cada vista.
select
    fct.fecha_movimiento,
    dim_fecha.dia_semana_nombre,
    dim_fecha.estacion,
    dim_finca.nombre_finca,
    fct.insumo_nombre,
    fct.insumo_categoria_al_momento as categoria,
    fct.insumo_unidad_base as unidad,
    fct.tipo_movimiento,
    fct.cantidad_base,
    fct.costo_total,
    fct.proveedor,
    fct.numero_lote,
    fct.fecha_vencimiento,
    fct.motivo

from {{ ref('fct_movimiento_insumo') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.finca_asociada = dim_finca.nombre_finca
inner join {{ ref('dim_fecha') }} as dim_fecha
    on fct.fecha_movimiento = dim_fecha.fecha

order by fct.fecha_movimiento desc
