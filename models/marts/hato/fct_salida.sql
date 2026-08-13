-- Grano: una salida/baja de un animal.
--
-- id_animal referencia dim_animal.id_animal (no único ahí — SCD2). motivo
-- se conserva como texto libre (no FK estricta a dim_motivo_salida — mismo
-- criterio que catalogo_veterinarios en otros módulos: el catálogo existe
-- para autocompletar/alta automática, no para forzar integridad
-- referencial dura).
select
    id_registro,
    fecha_salida,
    id_animal,
    arete_animal,
    motivo,
    observaciones,
    finca_asociada,
    id_finca,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('stg_ranchos__salidas') }}
