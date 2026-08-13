-- Grano: una versión histórica de un animal (SCD tipo 2 sobre
-- lote/categoria_animal/estado — ver snapshots/snapshot_animal.sql).
select
    dbt_scd_id as sk_animal,
    id_animal,
    arete,
    chip,
    sexo,
    fecha_nacimiento,
    id_madre,
    id_padre,
    padre_tipo,
    foto_url,
    lote,
    categoria_animal,
    estado,
    finca_asociada,
    dbt_valid_from as vigente_desde,
    dbt_valid_to as vigente_hasta,
    dbt_valid_to is null as vigente

from {{ ref('snapshot_animal') }}
