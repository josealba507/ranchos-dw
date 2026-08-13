-- L4 — Vista de negocio (docs/dama_governance.md sección 2 y 5): estado
-- ACTUAL del hato (filtra dim_animal a vigente=true), no el histórico
-- completo — es lo que un usuario de negocio espera al preguntar "cuántos
-- animales tengo", no las N versiones históricas de cada uno.
select
    dim_animal.id_animal,
    dim_animal.arete,
    dim_animal.chip,
    dim_animal.sexo,
    dim_animal.fecha_nacimiento,
    dim_animal.lote,
    dim_animal.categoria_animal,
    dim_finca.nombre_finca

from {{ ref('dim_animal') }} as dim_animal
inner join {{ ref('dim_finca') }} as dim_finca
    on dim_animal.finca_asociada = dim_finca.nombre_finca

where
    dim_animal.vigente = true
    and dim_animal.estado = 'Activo'

order by dim_animal.arete
