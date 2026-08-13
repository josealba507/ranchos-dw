-- L2 — Integración (ver docs/dama_governance.md sección 2): conforma cada
-- movimiento con la versión de insumo VIGENTE AL MOMENTO del movimiento,
-- no la versión actual del insumo — así un reporte histórico refleja la
-- categoría/presentación/estado reales que tenía el insumo cuando ocurrió
-- el movimiento, no los de hoy. Ephemeral: se inlinea en
-- fct_movimiento_insumo, no persiste como tabla propia.
--
-- Aproximación de grano temporal: fecha_movimiento es DATE (sin hora — ver
-- docs/fase0_inspeccion.md sección 0.3, no hay serverTimestamp() en el
-- proyecto operacional), así que se compara a medianoche UTC contra el
-- rango [dbt_valid_from, dbt_valid_to) del snapshot. Para la cadencia de
-- cambios de este catálogo (edición manual ocasional, no varias veces por
-- día), el error de hasta un día es aceptable.
--
-- Fallback obligatorio para movimientos MÁS VIEJOS que el primer snapshot
-- tomado: `dbt snapshot` no tiene histórico retroactivo — la primera vez
-- que corre, TODAS las versiones nacen con dbt_valid_from = el momento de
-- esa corrida (confirmado empíricamente: los 89 movimientos reales de
-- este proyecto son anteriores a la primera corrida de snapshot_insumo,
-- así que sin fallback ninguno matchearía). Prioridad 1: el movimiento
-- cae dentro de un rango de vigencia real. Prioridad 2 (fallback): se usa
-- la versión más antigua conocida del insumo — la mejor aproximación
-- disponible cuando no existe ningún registro histórico anterior al
-- movimiento. A medida que pasen ediciones reales de insumos después de
-- hoy, el snapshot va acumulando historia real y la prioridad 1 empieza a
-- aplicar para movimientos futuros.
with movimientos as (

    select * from {{ ref('stg_ranchos__movimientos_insumos') }}

),

insumo_historico as (

    select * from {{ ref('snapshot_insumo') }}

),

candidatos as (

    select
        movimientos.*,
        insumo_historico.nombre as insumo_nombre,
        insumo_historico.unidad_base as insumo_unidad_base,
        insumo_historico.categoria as insumo_categoria_al_momento,
        insumo_historico.presentacion as insumo_presentacion_al_momento,
        insumo_historico.estado as insumo_estado_al_momento,
        row_number() over (
            partition by movimientos.id_registro
            order by
                case
                    when
                        cast(movimientos.fecha_movimiento as timestamp) >= insumo_historico.dbt_valid_from
                        and (
                            cast(movimientos.fecha_movimiento as timestamp) < insumo_historico.dbt_valid_to
                            or insumo_historico.dbt_valid_to is null
                        )
                        then 1
                    else 2
                end asc,
                insumo_historico.dbt_valid_from asc
        ) as prioridad_rn

    from movimientos
    left join insumo_historico
        on movimientos.id_insumo = insumo_historico.id_insumo

)

select * except (prioridad_rn) from candidatos
where prioridad_rn = 1
