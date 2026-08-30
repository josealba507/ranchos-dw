-- L4 — Reporte OPERATIVO (docs/dama_governance.md sección 2 y 5).
--
-- No es una métrica: es una planilla de trabajo. Se exporta o se imprime
-- y se llena en el campo mientras se palpa. Por eso no lleva el prefijo
-- rpt_metrica_.
--
-- GRANO: una fila por vaca pendiente de palpar.
--
-- QUIÉN ENTRA: hembras activas que NO están preñadas hoy y que además
--   a) llevan al menos {{ var('dias_espera_voluntaria') }} días desde el
--      parto (pasaron el período de espera voluntario), o
--   b) su último palpamiento las dejó Vacía Ciclando o Vacía Anestro.
-- Una vaca preñada no se palpa de nuevo para diagnóstico, así que queda
-- fuera por definición.
--
-- TIENE QUE SER VISTA, NUNCA TABLA: fecha_reporte y todos los dias_*
-- usan current_date(). Materializarla como tabla congelaría la planilla
-- en la fecha del último build — se saldría al campo con una lista
-- vencida sin ninguna señal de que lo está. Ver la misma nota en
-- rpt_metrica_estado_reproductivo.sql.
--
-- LAS 2 ÚLTIMAS COLUMNAS SON INTENCIONALMENTE VACÍAS. No es un bug ni un
-- join que falló: son el espacio de captura para anotar en el campo la
-- fecha y el resultado del palpamiento que se está por hacer. Siempre van
-- a ser null en el warehouse, y por eso están excluidas de los tests
-- not_null. Si alguien las "arregla" en el futuro, rompe el propósito del
-- reporte.
with hembras_activas as (

    select
        id_animal,
        arete,
        chip,
        lote,
        finca_asociada

    from {{ ref('dim_animal') }}
    where vigente = true
      and sexo = 'Hembra'

),

ultimo_palpamiento as (

    select
        id_animal,
        fecha_palpamiento,
        resultado

    from (
        select
            id_animal,
            fecha_palpamiento,
            resultado,
            row_number() over (
                partition by id_animal order by fecha_palpamiento desc
            ) as orden
        from {{ ref('fct_palpamiento') }}
    )
    where orden = 1

),

ultimo_parto as (

    select
        id_madre as id_animal,
        max(fecha_parto) as fecha_ultimo_parto

    from {{ ref('fct_parto') }}
    where id_madre is not null
    group by 1

),

candidatas as (

    select
        hembras_activas.finca_asociada,
        hembras_activas.lote,
        hembras_activas.arete,
        hembras_activas.chip,
        hembras_activas.id_animal,
        ultimo_palpamiento.fecha_palpamiento,
        ultimo_palpamiento.resultado,
        ultimo_parto.fecha_ultimo_parto,

        date_diff(current_date(), ultimo_parto.fecha_ultimo_parto, day)
            as dias_desde_ultimo_parto,

        ultimo_palpamiento.resultado = 'Preñada'
        and (
            ultimo_parto.fecha_ultimo_parto is null
            or ultimo_parto.fecha_ultimo_parto <= ultimo_palpamiento.fecha_palpamiento
        ) as esta_prenada

    from hembras_activas
    inner join ultimo_palpamiento
        on hembras_activas.id_animal = ultimo_palpamiento.id_animal
    left join ultimo_parto
        on hembras_activas.id_animal = ultimo_parto.id_animal

)

select
    current_date() as fecha_reporte,
    candidatas.finca_asociada as nombre_finca,
    candidatas.lote,
    candidatas.arete,
    candidatas.chip,

    candidatas.fecha_ultimo_parto,
    candidatas.dias_desde_ultimo_parto,

    -- Días abiertos aproximados: días post-parto descontando el período
    -- de espera voluntario, o sea cuánto lleva REALMENTE disponible sin
    -- preñarse. No es el "días abiertos" clásico de la industria (que
    -- cuenta desde el parto hasta la concepción, espera incluida) — es
    -- una definición operativa propia de la finca. Nombrado _aprox para
    -- que nadie lo compare contra un benchmark externo sin notarlo.
    candidatas.dias_desde_ultimo_parto - {{ var('dias_espera_voluntaria') }}
        as dias_abiertos_aprox,

    candidatas.fecha_palpamiento as fecha_ultimo_palpamiento,
    date_diff(current_date(), candidatas.fecha_palpamiento, day)
        as dias_desde_ultimo_palpamiento,
    candidatas.resultado as resultado_ultimo_palpamiento,

    -- Columnas de captura en campo — siempre null a propósito (ver
    -- cabecera).
    cast(null as date) as fecha_palpamiento_nuevo,
    cast(null as string) as resultado_palpamiento_nuevo

from candidatas

where not candidatas.esta_prenada
  and (
      candidatas.dias_desde_ultimo_parto >= {{ var('dias_espera_voluntaria') }}
      or candidatas.resultado in ('Vacía Ciclando', 'Vacía Anestro')
  )

-- Orden de recorrido en el campo: lote por lote, y dentro de cada lote
-- las más atrasadas primero.
order by
    candidatas.finca_asociada,
    candidatas.lote,
    candidatas.dias_desde_ultimo_parto desc
