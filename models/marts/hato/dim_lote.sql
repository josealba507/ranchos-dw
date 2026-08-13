-- Grano: una versión histórica de un lote de manejo (SCD tipo 2 sobre
-- nombre/estado — ver snapshots/snapshot_lote.sql).
select
    dbt_scd_id as sk_lote,
    id_item as id_lote,
    nombre,
    estado,
    finca_asociada,
    dbt_valid_from as vigente_desde,
    dbt_valid_to as vigente_hasta,
    dbt_valid_to is null as vigente

from {{ ref('snapshot_lote') }}
