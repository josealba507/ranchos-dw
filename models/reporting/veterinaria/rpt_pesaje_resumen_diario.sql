-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5). Agrupa
-- por animal+día sumando los litros de todos los ordeños (Mañana/Tarde)
-- — mismo criterio de agrupación que ya usa ranchos--app en el perfil de
-- animal y en el Historial de Pesaje (ver CLAUDE.md de ese repo, "Fix
-- post-producción: Pesaje del perfil sumaba mal el último día"), para no
-- repetir acá el bug histórico de tomar solo un ordeño.
select
    dim_finca.nombre_finca,
    fct.fecha_pesaje,
    fct.arete_animal,
    sum(fct.litros) as litros_totales_dia,
    count(*) as cantidad_ordenos

from {{ ref('fct_pesaje') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.finca_asociada = dim_finca.nombre_finca

group by 1, 2, 3

order by 2 desc
