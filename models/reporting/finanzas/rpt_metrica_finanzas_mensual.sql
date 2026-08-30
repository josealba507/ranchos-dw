-- L4 — Capa de métricas (docs/dama_governance.md sección 2 y 5).
--
-- GRANO: una fila por finca + mes + tipo de transacción + categoría +
-- clase. Es el grano más fino que sigue siendo una métrica agregada: el
-- detalle transacción por transacción vive en
-- rpt_transacciones_financieras_recientes.
--
-- SIGNO — la decisión de negocio central de este modelo. monto_total en la
-- fuente es SIEMPRE POSITIVO, sin importar si el dinero entra o sale; lo
-- que determina la dirección es tipo_transaccion. Sumar monto_total sin
-- signar daría "gastos + ingresos" mezclados, un número sin significado.
-- Acá se aplica la convención de ranchos--app (ver el KPI "Balance a la
-- Fecha" en el CLAUDE.md de ese repo): Entrada suma, Salida e Inversion
-- restan.
--
-- Inversion resta junto con Salida porque desde la caja de la finca ambas
-- son salidas de dinero; la diferencia entre gasto e inversión es
-- contable, no de flujo. Quien necesite separarlas tiene tipo_transaccion
-- como columna y puede filtrar.
with transacciones as (

    select
        fct.id_finca,
        fct.fecha_transaccion,
        fct.tipo_transaccion,
        fct.categoria,
        fct.clase,
        fct.monto_total,

        case
            when fct.tipo_transaccion = 'Entrada' then fct.monto_total
            else -fct.monto_total
        end as monto_con_signo

    from {{ ref('fct_transaccion_financiera') }} as fct

),

agregado as (

    select
        dim_fecha.anio,
        dim_fecha.mes,
        dim_fecha.mes_nombre,
        dim_fecha.estacion,
        dim_finca.nombre_finca,
        transacciones.tipo_transaccion,
        transacciones.categoria,
        transacciones.clase,

        count(*) as cantidad_transacciones,
        sum(transacciones.monto_total) as monto_total,
        sum(transacciones.monto_con_signo) as resultado_neto,
        min(transacciones.fecha_transaccion) as primera_transaccion,
        max(transacciones.fecha_transaccion) as ultima_transaccion

    from transacciones
    inner join {{ ref('dim_finca') }} as dim_finca
        on transacciones.id_finca = dim_finca.id_finca
    inner join {{ ref('dim_fecha') }} as dim_fecha
        on transacciones.fecha_transaccion = dim_fecha.fecha

    group by 1, 2, 3, 4, 5, 6, 7, 8

)

select * from agregado

order by anio desc, mes desc, nombre_finca, categoria
