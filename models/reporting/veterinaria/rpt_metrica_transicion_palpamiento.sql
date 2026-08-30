-- L4 — Capa de métricas (docs/dama_governance.md sección 2 y 5).
--
-- GRANO: una fila por PALPAMIENTO, con su transición respecto al
-- palpamiento anterior de la misma vaca. Los conteos que pide el negocio
-- (cuántas mejoraron, cuántas mantienen, cuántas empeoraron) salen de
-- agrupar por transicion — por eso el grano es el evento y no el
-- agregado mensual.
--
-- ESCALA ORDINAL: la clasificación se apoya en un orden reproductivo
-- explícito, confirmado con el usuario:
--     Vacía Anestro (1) < Vacía Ciclando (2) < Preñada (3)
-- Anestro es el peor estado (la vaca ni siquiera está ciclando), Preñada
-- el objetivo. Mejoró = sube de rango, Mantiene = igual, Empeoró = baja.
--
-- POR QUÉ EXISTE 'Ciclo completado' — la corrección más importante de
-- este modelo. Una vaca Preñada que en el siguiente palpamiento aparece
-- Vacía bajó de rango, pero NO siempre es un aborto: si parió entre
-- ambos palpamientos, completó su ciclo normalmente. Medido contra
-- producción (2026-08-24): de 17 transiciones Preñada→Vacía, 3 tenían un
-- parto en el medio. Sin esta distinción el reporte mandaría a investigar
-- 3 vacas sanas como posibles abortos.
--
-- No se usa estado_gestacion (el campo que la app marca como 'Parió')
-- porque es null en 219 de 224 registros: se agregó después de la carga
-- histórica. La verificación contra fct_parto cubre todo el histórico.
with palpamientos as (

    select
        id_registro,
        id_animal,
        arete_animal,
        fecha_palpamiento,
        resultado,
        finca_asociada,

        case resultado
            when 'Vacía Anestro' then 1
            when 'Vacía Ciclando' then 2
            when 'Preñada' then 3
        end as rango_reproductivo

    from {{ ref('fct_palpamiento') }}

),

con_previo as (

    select
        palpamientos.*,

        lag(resultado) over (
            partition by id_animal order by fecha_palpamiento
        ) as resultado_previo,

        lag(rango_reproductivo) over (
            partition by id_animal order by fecha_palpamiento
        ) as rango_previo,

        lag(fecha_palpamiento) over (
            partition by id_animal order by fecha_palpamiento
        ) as fecha_palpamiento_previo,

        row_number() over (
            partition by id_animal order by fecha_palpamiento desc
        ) = 1 as es_ultimo_palpamiento

    from palpamientos

),

con_parto as (

    select
        con_previo.*,

        -- ¿Parió entre el palpamiento anterior y este? Si sí, la caída de
        -- Preñada a Vacía es un ciclo cerrado, no una pérdida.
        exists (
            select 1
            from {{ ref('fct_parto') }} as parto
            where parto.id_madre = con_previo.id_animal
              and parto.fecha_parto > con_previo.fecha_palpamiento_previo
              and parto.fecha_parto <= con_previo.fecha_palpamiento
        ) as parto_entre_palpamientos

    from con_previo

)

select
    con_parto.finca_asociada as nombre_finca,
    con_parto.arete_animal,
    con_parto.fecha_palpamiento,
    con_parto.resultado,
    con_parto.fecha_palpamiento_previo,
    con_parto.resultado_previo,

    date_diff(
        con_parto.fecha_palpamiento,
        con_parto.fecha_palpamiento_previo,
        day
    ) as dias_entre_palpamientos,

    case
        when con_parto.rango_previo is null then 'Primer palpamiento'
        when con_parto.parto_entre_palpamientos
             and con_parto.rango_previo = 3 then 'Ciclo completado'
        when con_parto.rango_reproductivo > con_parto.rango_previo then 'Mejoró'
        when con_parto.rango_reproductivo = con_parto.rango_previo then 'Mantiene'
        else 'Empeoró'
    end as transicion,

    case
        when con_parto.rango_previo is null
            then concat('(primero) → ', con_parto.resultado)
        else concat(con_parto.resultado_previo, ' → ', con_parto.resultado)
    end as detalle_transicion,

    -- Preñada que dejó de estarlo SIN parto de por medio. Es una señal
    -- para revisar, no un diagnóstico veterinario confirmado.
    coalesce(
        con_parto.rango_previo = 3
        and con_parto.rango_reproductivo < 3
        and not con_parto.parto_entre_palpamientos,
        false
    ) as posible_aborto,

    con_parto.parto_entre_palpamientos,
    con_parto.es_ultimo_palpamiento,
    con_parto.id_registro

from con_parto

order by con_parto.fecha_palpamiento desc
