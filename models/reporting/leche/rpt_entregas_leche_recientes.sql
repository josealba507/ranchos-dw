-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5).
select
    fct.fecha_pago,
    dim_fecha.dia_semana_nombre,
    dim_fecha.estacion,
    dim_finca.nombre_finca,
    fct.litros_entrega,
    fct.valor_entrega_bruta,
    fct.multa,
    fct.valor_entrega_neta,
    fct.valor_litro_total

from {{ ref('fct_venta_leche') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.id_finca = dim_finca.id_finca
inner join {{ ref('dim_fecha') }} as dim_fecha
    on fct.fecha_pago = dim_fecha.fecha

order by fct.fecha_pago desc
