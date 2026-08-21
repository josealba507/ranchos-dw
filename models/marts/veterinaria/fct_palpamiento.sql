-- Grano: un palpamiento (diagnóstico reproductivo).
--
-- veterinario se conserva como texto libre (no FK estricta a
-- dim_veterinario) — mismo criterio que motivo en fct_salida: el
-- catálogo existe para autocompletar/alta automática, no para forzar
-- integridad referencial dura.
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
{{
    config(
        partition_by={'field': 'fecha_palpamiento', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['finca_asociada', 'id_animal']
    )
}}
select
    id_registro,
    fecha_palpamiento,
    id_animal,
    arete_animal,
    resultado,
    dias_gestacion,
    fecha_parto_esperada,
    estado_gestacion,
    meses_atraso,
    veterinario,
    comentario,
    finca_asociada,
    id_finca,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__palpamientos') }}
