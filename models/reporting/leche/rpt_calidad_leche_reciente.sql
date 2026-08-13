-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5). Combina
-- microbiología y composición (mismo grano de negocio — calidad de una
-- muestra tomada en una fecha) vía FULL OUTER JOIN por finca+fecha, ya
-- que son 2 fact tables independientes que pueden o no coincidir en fecha
-- exacta de muestreo.
with microbiologia as (
    select * from {{ ref('fct_microbiologia_leche') }}
),

composicion as (
    select * from {{ ref('fct_composicion_leche') }}
)

select
    dim_finca.nombre_finca,
    microbiologia.microbiologia_muestra,
    composicion.composicion_grasa,
    composicion.composicion_proteina,
    composicion.composicion_lactosa,
    composicion.composicion_st,
    composicion.composicion_sng,
    composicion.celulas_somaticas,
    coalesce(microbiologia.fecha_muestra, composicion.fecha_muestra) as fecha_muestra,
    coalesce(microbiologia.id_finca, composicion.id_finca) as id_finca

from microbiologia
full outer join composicion
    on
        microbiologia.fecha_muestra = composicion.fecha_muestra
        and microbiologia.id_finca = composicion.id_finca
inner join {{ ref('dim_finca') }} as dim_finca
    on coalesce(microbiologia.id_finca, composicion.id_finca) = dim_finca.id_finca

order by fecha_muestra desc
