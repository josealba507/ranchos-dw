-- L4 — Capa de métricas (docs/dama_governance.md sección 2 y 5).
--
-- GRANO: una fila por insumo (dentro de una finca). Es una métrica de
-- SALDO, no una serie temporal: responde "cuánto tengo hoy", no "cómo
-- evolucionó". La evolución movimiento a movimiento vive en
-- rpt_movimientos_insumo_recientes.
--
-- cantidad_base YA TRAE SU SIGNO por movimiento — confirmado
-- empíricamente contra producción (ver el comentario extenso en
-- tests/exactitud_existencia_insumo_vs_ledger.sql): inicial/compra
-- positivos, merma negativo, conteo puede ser cualquiera (el delta de
-- ajuste). Por eso la existencia es un sum() directo y NO hay que signar
-- por tipo_movimiento acá — hacerlo duplicaría el signo y daría saldos
-- invertidos.
--
-- Este saldo se calcula desde el LEDGER (la suma de movimientos), no se
-- lee el saldo cacheado que mantiene la app. Que ambos coincidan es
-- justamente lo que verifica el test de exactitud citado arriba — si acá
-- se leyera el cacheado, la métrica y su control de calidad estarían
-- mirando la misma fuente y el test no probaría nada.
with movimientos as (

    select
        id_insumo,
        insumo_nombre,
        insumo_unidad_base,
        insumo_categoria_al_momento,
        finca_asociada,
        tipo_movimiento,
        cantidad_base,
        costo_total,
        fecha_movimiento

    from {{ ref('fct_movimiento_insumo') }}

),

saldo as (

    select
        movimientos.finca_asociada,
        movimientos.id_insumo,
        movimientos.insumo_nombre,
        movimientos.insumo_unidad_base as unidad,

        -- La categoría de un insumo puede cambiar (está historizada SCD2);
        -- acá interesa con cuál está clasificado en su movimiento más
        -- reciente, que es como lo ve hoy quien mira el inventario.
        max(movimientos.insumo_categoria_al_momento) as categoria,

        sum(movimientos.cantidad_base) as existencia_actual,
        count(*) as cantidad_movimientos,
        sum(
            case when movimientos.tipo_movimiento = 'compra'
                then movimientos.costo_total
            end
        ) as costo_total_comprado,
        min(movimientos.fecha_movimiento) as primer_movimiento,
        max(movimientos.fecha_movimiento) as ultimo_movimiento

    from movimientos
    group by 1, 2, 3, 4

)

select
    saldo.finca_asociada as nombre_finca,
    saldo.id_insumo,
    saldo.insumo_nombre,
    saldo.categoria,
    saldo.unidad,
    saldo.existencia_actual,
    saldo.cantidad_movimientos,
    saldo.costo_total_comprado,
    saldo.primer_movimiento,
    saldo.ultimo_movimiento,

    -- Señal operativa: un saldo negativo es imposible físicamente, así que
    -- delata un movimiento mal capturado (una merma mayor al stock real, o
    -- una compra que nunca se registró). Se expone como bandera en vez de
    -- filtrarse, para que el error sea visible en el tablero y no
    -- silenciosamente excluido.
    saldo.existencia_actual < 0 as existencia_negativa

from saldo

order by saldo.finca_asociada, saldo.insumo_nombre
