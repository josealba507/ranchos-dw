-- Grano: una medicina. Sin historización.
select
    id_medicina,
    nombre,
    estado,
    finca_asociada

from {{ ref('stg_ranchos__catalogo_medicinas') }}
