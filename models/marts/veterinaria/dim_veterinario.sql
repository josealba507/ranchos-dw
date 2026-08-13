-- Grano: un veterinario. Sin historización.
select
    id_veterinario,
    nombre,
    estado,
    finca_asociada

from {{ ref('stg_ranchos__catalogo_veterinarios') }}
