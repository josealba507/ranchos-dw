-- Grano: un tratamiento veterinario.
--
-- medicina/motivo/veterinario se conservan como texto libre — mismo
-- criterio que fct_palpamiento.
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_tratamiento', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['finca_asociada', 'id_animal']
    )
}}
select
    id_registro,
    fecha_tratamiento,
    id_animal,
    arete_animal,
    motivo,
    medicina,
    cantidad,
    unidad,
    dias_retiro,
    veterinario,
    finca_asociada,
    id_finca,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__tratamientos') }}
