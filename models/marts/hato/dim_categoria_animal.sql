-- Grano: una categoría de animal. Sin historización (ver
-- stg_ranchos__catalogo_categorias_animal.sql).
select
    id_item as id_categoria_animal,
    nombre,
    estado,
    finca_asociada

from {{ ref('stg_ranchos__catalogo_categorias_animal') }}
