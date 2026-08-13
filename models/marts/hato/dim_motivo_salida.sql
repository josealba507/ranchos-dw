-- Grano: un motivo de salida. Sin historización.
select
    id_motivo,
    nombre,
    estado,
    finca_asociada

from {{ ref('stg_ranchos__catalogo_motivos_salida') }}
