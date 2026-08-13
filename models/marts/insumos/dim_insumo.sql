-- Grano: una versión histórica de un insumo — un insumo tiene N filas acá
-- si cambió de categoria/presentacion/estado N-1 veces (SCD tipo 2).
--
-- Construida sobre snapshot_insumo (L2), que es donde vive la
-- historización real (Fase 4 del documento de especificación). Quien
-- consulte esta tabla sin filtrar por vigente=true ve el histórico
-- completo; con el filtro, ve el estado actual — mismo resultado que
-- estado_registro='Activo' en las fact tables de origen, pero acá
-- resuelto con SCD2 real (múltiples filas por entidad) en vez de una
-- sola fila reemplazada in-place.
select
    -- Surrogate key real de esta tabla: id_insumo NO es único acá (SCD2,
    -- una fila por versión histórica) — dbt_scd_id sí lo es, generado por
    -- el propio mecanismo de snapshot.
    dbt_scd_id as sk_insumo,
    id_insumo,
    nombre,
    unidad_base,
    maneja_vencimiento,
    categoria,
    presentacion,
    estado,
    finca_asociada,
    dbt_valid_from as vigente_desde,
    dbt_valid_to as vigente_hasta,
    dbt_valid_to is null as vigente

from {{ ref('snapshot_insumo') }}
