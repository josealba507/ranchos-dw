-- Grano: un día calendario.
--
-- Dimensión conformada, generada (Fase 4 del documento de especificación)
-- — no viene de ninguna fuente, se construye con dbt_utils.date_spine().
-- Rango 2020-01-01 a 2035-12-31: cubre con margen el histórico real más
-- antiguo del proyecto (animales con fecha_nacimiento desde 2023, ver
-- CLAUDE.md de ranchos--app) y varios años hacia adelante sin necesitar
-- regenerar la tabla seguido.
--
-- Nombres de día/mes en español a mano (no FORMAT_DATE: su locale es fijo
-- en inglés en BigQuery, sin parámetro para cambiarlo) — mismo criterio
-- de idioma que el resto del proyecto (español para negocio).
with fechas as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2020-01-01' as date)",
        end_date="cast('2036-01-01' as date)"
    ) }}

),

enriquecido as (

    select
        date_day as fecha,
        cast(null as string) as ciclo_productivo,
        extract(year from date_day) as anio,
        extract(month from date_day) as mes,
        extract(day from date_day) as dia,
        -- BigQuery: 1=domingo ... 7=sábado.
        extract(quarter from date_day) as trimestre,
        extract(dayofweek from date_day) as dia_semana_numero,

        extract(dayofweek from date_day) in (1, 7) as es_fin_de_semana,

        case extract(month from date_day)
            when 1 then 'Enero' when 2 then 'Febrero' when 3 then 'Marzo'
            when 4 then 'Abril' when 5 then 'Mayo' when 6 then 'Junio'
            when 7 then 'Julio' when 8 then 'Agosto' when 9 then 'Septiembre'
            when 10 then 'Octubre' when 11 then 'Noviembre' when 12 then 'Diciembre'
        end as mes_nombre,

        -- Estación climática de Panamá (confirmado con el usuario,
        -- 2026-08-13): seca diciembre-abril, lluviosa mayo-noviembre. Es
        -- un predictor fuerte del consumo de alimento (Fase 4 del
        -- documento de especificación) — se calcula una sola vez acá, no
        -- en cada consulta. Si alguna finca de microclima distinto se
        -- suma al proyecto, esta regla dejaría de ser universal — hoy
        -- solo hay una finca real (Ganadera Alba Guerra, ver
        -- docs/fase0_inspeccion.md), así que no hace falta un atributo
        -- por finca todavía.
        case extract(dayofweek from date_day)
            when 1 then 'Domingo' when 2 then 'Lunes' when 3 then 'Martes'
            when 4 then 'Miércoles' when 5 then 'Jueves' when 6 then 'Viernes'
            when 7 then 'Sábado'
        end as dia_semana_nombre,

        -- Pendiente de definir con el usuario — sin concepto de negocio
        -- confirmado todavía (ver docs/fase2_arquitectura.md, Punto de
        -- Control 2). No bloquea el resto de la dimensión: se deja NULL
        -- hasta que se defina, en vez de inventar una taxonomía.
        case
            when extract(month from date_day) in (12, 1, 2, 3, 4) then 'Seca'
            else 'Lluviosa'
        end as estacion

    from fechas

)

select * from enriquecido
