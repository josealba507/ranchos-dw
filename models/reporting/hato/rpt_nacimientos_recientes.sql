-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5).
select
    fct.fecha_parto,
    dim_fecha.dia_semana_nombre,
    dim_fecha.estacion,
    dim_finca.nombre_finca,
    fct.arete_madre,
    fct.sexo_cria,
    fct.arete_cria,
    fct.chip_cria,
    fct.observaciones

from {{ ref('fct_parto') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.finca_asociada = dim_finca.nombre_finca
inner join {{ ref('dim_fecha') }} as dim_fecha
    on fct.fecha_parto = dim_fecha.fecha

order by fct.fecha_parto desc
