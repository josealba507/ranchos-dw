-- L4 — Capa de métricas (docs/dama_governance.md sección 2 y 5).
--
-- GRANO: una fila por ENTREGA de leche (una liquidación pagada por el
-- comprador a una finca). NO es mensual a propósito: el grano atómico
-- permite que el dashboard agregue por mes, trimestre o estación con un
-- group by, mientras que una vista ya agregada no se puede desagregar.
--
-- OJO CON LA FECHA: fecha_pago es la fecha en que el comprador PAGÓ la
-- entrega, no la fecha en que se ordeñó la leche. Un análisis de
-- estacionalidad productiva sobre esta columna mide el calendario de pagos
-- del comprador, no el de producción de la finca. Para producción por
-- animal existe rpt_pesaje_resumen_diario, que sí tiene grano de ordeño.
--
-- VALORES POR LITRO: se toman TAL CUAL de fct_venta_leche, NO se
-- recalculan acá. Los 5 valores derivados de una entrega (bruta, neta y
-- los 3 por litro) los calcula server-side la Cloud Function de pago de
-- ranchos--app, que es la fuente de verdad del monto que se le paga a la
-- finca. Verificado empíricamente contra producción (2026-08-24):
-- valor_entrega_bruta / litros_entrega coincide exactamente con
-- valor_litro_total en las 84 entregas, 0 discrepancias. Recalcularlos acá
-- daría el mismo número HOY, pero divergiría en silencio si esa función
-- cambiara una regla de redondeo — y el warehouse estaría contradiciendo
-- al sistema que emite el pago.
--
-- CALIDAD DE LECHE (bacterias/composición) NO se une acá, por decisión
-- explícita: se muestrea en fechas propias, independientes de la entrega,
-- así que cualquier join sería por proximidad y no por clave (medido: solo
-- 28 de 84 entregas coinciden en fecha exacta con una muestra). Vive en su
-- propio grano en rpt_calidad_leche_reciente.
select
    fct.fecha_pago,
    dim_fecha.anio,
    dim_fecha.mes,
    dim_fecha.mes_nombre,
    dim_fecha.estacion,
    dim_finca.nombre_finca,

    fct.litros_entrega,

    -- Montos de la entrega (moneda de la finca)
    fct.valor_entrega_bruta,
    fct.incentivo_valor,
    fct.multa,
    fct.valor_entrega_neta,

    -- Precios unitarios calculados server-side (ver nota de cabecera)
    fct.valor_litro_base,
    fct.valor_litro_incentivo,
    fct.valor_litro_total,

    fct.id_registro

from {{ ref('fct_venta_leche') }} as fct
inner join {{ ref('dim_finca') }} as dim_finca
    on fct.id_finca = dim_finca.id_finca
inner join {{ ref('dim_fecha') }} as dim_fecha
    on fct.fecha_pago = dim_fecha.fecha

order by fct.fecha_pago desc
