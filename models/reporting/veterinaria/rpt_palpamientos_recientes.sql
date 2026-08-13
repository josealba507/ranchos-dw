-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5).
select
    fct.fecha_palpamiento,
    dim_fecha.dia_semana_nombre,
    dim_fecha.estacion,
    dim_finca.nombre_finca,
    fct.arete_animal,
    fct.resultado,
    fct.dias_gestacion,
    fct.fecha_parto_esperada,
    fct.estado_gestacion,
    fct.meses_atraso,
    fct.veterinario

from {{ ref('fct_palpamiento') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.finca_asociada = dim_finca.nombre_finca
inner join {{ ref('dim_fecha') }} as dim_fecha
    on fct.fecha_palpamiento = dim_fecha.fecha

order by fct.fecha_palpamiento desc
