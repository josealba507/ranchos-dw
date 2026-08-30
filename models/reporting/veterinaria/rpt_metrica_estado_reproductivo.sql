-- L4 — Capa de métricas (docs/dama_governance.md sección 2 y 5).
--
-- GRANO: una fila por hembra ACTIVA que tiene al menos un palpamiento.
-- Es el tablero del estado reproductivo del hato AHORA.
--
-- TIENE QUE SER VISTA, NUNCA TABLA. Las columnas dias_desde_* usan
-- current_date(), así que se recalculan en cada consulta. Si alguien
-- materializa este modelo como tabla, esos días quedan congelados en la
-- fecha del último build y el tablero miente sin dar ninguna señal de
-- error. La capa reporting ya es +materialized: view por defecto en
-- dbt_project.yml; esta nota existe para que nadie lo cambie sin saberlo.
--
-- POR QUÉ SOLO HEMBRAS PALPADAS: se excluye deliberadamente a las hembras
-- sin ningún palpamiento. Clasificarlas exigiría apoyarse en edad y
-- categoría, y hoy esos datos son aproximados — vienen de la carga
-- inicial, donde los animales sin fecha real recibieron una fecha fija.
-- Inventar estados reproductivos sobre datos que sabemos aproximados
-- daría un tablero preciso y equivocado. Cuando las edades reales estén
-- cargadas, se amplía el universo (la var meses_edad_reproductiva ya
-- está declarada para ese momento).
--
-- CORRECCIÓN POR PARTO: el estado NO se puede leer del último
-- palpamiento a secas. Medido contra producción (2026-08-24): 14 vacas
-- cuyo último palpamiento dice 'Preñada' ya parieron después de ese
-- palpamiento — reportarlas como preñadas sería un error en 14 de 60.
-- Por eso 'Parió' es un estado propio.
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
        resultado,
        fecha_parto_esperada,
        meses_atraso

    from (
        select
            id_animal,
            fecha_palpamiento,
            resultado,
            fecha_parto_esperada,
            meses_atraso,
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

-- Inicio del período abierto: desde cuándo la vaca lleva sin preñarse.
-- Si parió, se cuenta desde el parto (definición estándar). Si no hay
-- parto registrado, se usa el primer palpamiento vacío de su racha
-- actual — la mejor aproximación disponible con estos datos.
inicio_racha_vacia as (

    select
        palp.id_animal,
        min(palp.fecha_palpamiento) as primer_palpamiento_vacio

    from {{ ref('fct_palpamiento') }} as palp
    left join ultimo_parto
        on palp.id_animal = ultimo_parto.id_animal
    where palp.resultado != 'Preñada'
      and (
          ultimo_parto.fecha_ultimo_parto is null
          or palp.fecha_palpamiento > ultimo_parto.fecha_ultimo_parto
      )
    group by 1

),

base as (

    select
        hembras_activas.finca_asociada,
        hembras_activas.arete,
        hembras_activas.chip,
        hembras_activas.lote,
        hembras_activas.id_animal,

        ultimo_palpamiento.fecha_palpamiento,
        ultimo_palpamiento.resultado,
        ultimo_palpamiento.fecha_parto_esperada,
        ultimo_palpamiento.meses_atraso,
        ultimo_parto.fecha_ultimo_parto,
        inicio_racha_vacia.primer_palpamiento_vacio,

        -- Preñada de verdad: el último palpamiento dice Preñada Y no hay
        -- un parto posterior a ese palpamiento.
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
    left join inicio_racha_vacia
        on hembras_activas.id_animal = inicio_racha_vacia.id_animal

)

select
    current_date() as fecha_reporte,
    base.finca_asociada as nombre_finca,
    base.lote,
    base.arete,
    base.chip,

    case
        when base.esta_prenada then 'Preñada'
        when base.resultado = 'Preñada' then 'Parió'
        else base.resultado
    end as estado_reproductivo,

    base.resultado as resultado_ultimo_palpamiento,
    base.fecha_palpamiento as fecha_ultimo_palpamiento,
    date_diff(current_date(), base.fecha_palpamiento, day)
        as dias_desde_ultimo_palpamiento,

    base.fecha_ultimo_parto,
    date_diff(current_date(), base.fecha_ultimo_parto, day)
        as dias_desde_ultimo_parto,

    -- Días abiertos: solo tiene sentido si NO está preñada. En una vaca
    -- preñada el período abierto ya cerró el día que concibió.
    case
        when base.esta_prenada then null
        else coalesce(base.fecha_ultimo_parto, base.primer_palpamiento_vacio)
    end as fecha_inicio_periodo_abierto,

    case
        when base.esta_prenada then null
        else date_diff(
            current_date(),
            coalesce(base.fecha_ultimo_parto, base.primer_palpamiento_vacio),
            day
        )
    end as dias_abiertos,

    -- Fechas de la gestación en curso (nulas si no está preñada)
    case when base.esta_prenada then base.fecha_parto_esperada end
        as fecha_parto_esperada,

    case
        when base.esta_prenada
            then date_sub(
                base.fecha_parto_esperada,
                interval {{ var('dias_preparto') }} day
            )
    end as fecha_preparto,

    case
        when base.esta_prenada
            then date_diff(base.fecha_parto_esperada, current_date(), day)
    end as dias_para_parto,

    case when base.esta_prenada then base.meses_atraso end as meses_atraso,

    base.id_animal

from base

order by base.finca_asociada, base.lote, base.arete
