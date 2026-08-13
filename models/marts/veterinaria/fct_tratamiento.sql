-- Grano: un tratamiento veterinario.
--
-- medicina/motivo/veterinario se conservan como texto libre — mismo
-- criterio que fct_palpamiento.
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
