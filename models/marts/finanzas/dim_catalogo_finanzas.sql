-- Grano: un item del catálogo de categoría/clase de gasto por finca.
--
-- Sin historización (Fase 4 del documento de especificación: "sin
-- historización, si el análisis no lo requiere") — a diferencia de
-- Animal/Lote/Insumo, este catálogo no tiene un flujo de edición de
-- nombre documentado en producción (solo alta + soft-delete), así que
-- una fila reemplazada in-place no pierde información histórica
-- relevante para el negocio.
select
    id_item,
    tipo_transaccion,
    categoria,
    clase_gasto,
    estado,
    finca_asociada

from {{ ref('stg_ranchos__catalogo_finanzas') }}
