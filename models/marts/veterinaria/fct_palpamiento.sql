-- Grano: un palpamiento (diagnóstico reproductivo).
--
-- veterinario se conserva como texto libre (no FK estricta a
-- dim_veterinario) — mismo criterio que motivo en fct_salida: el
-- catálogo existe para autocompletar/alta automática, no para forzar
-- integridad referencial dura.
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
