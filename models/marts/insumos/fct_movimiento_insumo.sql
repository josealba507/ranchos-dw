-- Grano: un movimiento de inventario de un insumo (inicial/compra/conteo/
-- merma/ajuste — ver CLAUDE.md de ranchos--app, Módulo de Insumos).
--
-- id_usuario se conserva como dimensión degenerada (sin dim_usuario propia
-- todavía — fuera de alcance del Punto de Control 2, ver
-- docs/fase2_arquitectura.md; Fase 4 del documento de especificación lista
-- "usuario" como dimensión sin historización, pendiente para cuando un
-- segundo hecho la necesite).
--
-- factor_presentacion_copiado se conserva tal cual llega de staging —
-- vestigial desde PR #142/#137 de ranchos--app (siempre 1 en movimientos
-- recientes, ver docs/fase0_inspeccion.md hallazgo 4). costo_total es
-- NUMERIC, no centavos enteros — decisión ya tomada por el proyecto
-- operacional (ver docs/fase0_inspeccion.md, inconsistencia 1).
--
-- partition_by/cluster_by: al volumen actual el beneficio de costo es
-- marginal — la razón real es dejar el patrón correcto instalado antes
-- de que el volumen crezca (adelanta parte de la Fase 8 del plan).
-- Particiona por fecha_movimiento (el evento), no fecha_vencimiento
-- (un atributo del insumo).
{{
    config(
        partition_by={'field': 'fecha_movimiento', 'data_type': 'date', 'granularity': 'day'},
        cluster_by=['finca_asociada', 'id_insumo']
    )
}}
select
    id_registro,
    id_insumo,
    insumo_nombre,
    insumo_unidad_base,
    insumo_categoria_al_momento,
    insumo_presentacion_al_momento,
    insumo_estado_al_momento,
    tipo_movimiento,
    fecha_movimiento,
    cantidad_base,
    cantidad_capturada,
    id_presentacion,
    factor_presentacion_copiado,
    costo_total,
    proveedor,
    numero_lote,
    fecha_vencimiento,
    motivo,
    id_movimiento_compensado,
    id_periodo_generado,
    finca_asociada,
    id_finca,
    id_usuario,
    canal_captura,
    timestamp_registro

from {{ ref('int_movimientos_insumos_con_insumo_historico') }}
