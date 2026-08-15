-- Fase 5 (exactitud) — el ledger inmutable de movimientos debe reconciliar
-- EXACTAMENTE contra el saldo cacheado que ranchos--app mantiene en el
-- catálogo (existencia_actual, incrementado atómicamente por el cliente
-- vía FieldValue.increment en el mismo writeBatch que cada movimiento —
-- ver CLAUDE.md de ranchos--app, Módulo de Insumos). Si algún movimiento
-- se escribió sin su incremento correspondiente (o viceversa), este test
-- lo detecta — es la instancia concreta de la dimensión "Accuracy
-- (exactitud)" de docs/dama_governance.md, hasta ahora solo aspiracional
-- en esa tabla.
--
-- cantidad_base ya trae su propio signo por movimiento — confirmado
-- empíricamente contra producción (bq query directa sobre
-- tb_fact_movimientos_insumos, 2026-08-13): inicial/compra siempre
-- positivos, merma siempre negativo, conteo puede ser cualquiera (el
-- delta de ajuste tras la merma declarada). No hace falta signar por
-- tipo_movimiento acá.
--
-- existencia_actual se lee de staging, NO de dim_insumo: es un saldo que
-- cambia en cada movimiento, deliberadamente excluido de la
-- historización SCD2 (ver models/marts/insumos/dim_insumo.sql) porque el
-- snapshot solo versiona categoria/presentacion/estado — usar dim_insumo
-- acá daría un valor congelado desde la última vez que esas 3 columnas
-- cambiaron, no el saldo real actual.
--
-- INNER JOIN (no LEFT): un insumo sin ningún movimiento en el ledger no
-- tiene nada que reconciliar (alta con cantidad inicial 0, o catálogo
-- huérfano ya documentado en docs/fase0_inspeccion.md) — no es una
-- discrepancia real, y forzar el LEFT JOIN solo generaría ruido.

{{ config(store_failures=true, schema='metadata_ranchos', severity='error') }}

with ledger as (

    select
        id_insumo,
        sum(cantidad_base) as suma_ledger

    from {{ ref('fct_movimiento_insumo') }}
    group by id_insumo

),

catalogo as (

    select
        id_insumo,
        nombre,
        existencia_actual

    from {{ ref('stg_ranchos__catalogo_insumos') }}

)

select
    catalogo.id_insumo,
    catalogo.nombre,
    catalogo.existencia_actual,
    ledger.suma_ledger,
    round(catalogo.existencia_actual - ledger.suma_ledger, 4) as diferencia

from catalogo
inner join ledger on catalogo.id_insumo = ledger.id_insumo
where round(catalogo.existencia_actual - ledger.suma_ledger, 4) != 0
