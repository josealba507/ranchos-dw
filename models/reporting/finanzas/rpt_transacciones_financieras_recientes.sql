-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5): lo único
-- que BI/Looker Studio debe consultar para este dominio, no
-- marts_ranchos directo.
select
    fct.fecha_transaccion,
    dim_fecha.dia_semana_nombre,
    dim_fecha.estacion,
    dim_finca.nombre_finca,
    fct.tipo_transaccion,
    fct.categoria,
    fct.clase,
    fct.monto_total,
    fct.proveedor_tercero,
    fct.detalle_movimiento

from {{ ref('fct_transaccion_financiera') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.id_finca = dim_finca.id_finca
inner join {{ ref('dim_fecha') }} as dim_fecha
    on fct.fecha_transaccion = dim_fecha.fecha

order by fct.fecha_transaccion desc
