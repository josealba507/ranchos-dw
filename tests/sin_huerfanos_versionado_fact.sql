-- Fase 5 (consistencia) — ninguna tabla fact versionada puede tener un
-- "huérfano": un id_registro con una versión 'Corregido' y NINGUNA versión
-- vigente ('Activo') ni terminal ('Anulado').
--
-- Por qué existe: al corregir un documento de Firestore, las Cloud
-- Functions de ranchos--app marcan la fila vigente como 'Corregido' y luego
-- insertan la versión nueva 'Activo'. Si el segundo paso no entra, el
-- registro desaparece de todo reporte (los modelos filtran
-- estado_registro = 'Activo') sin ningún error visible. Eso pasó de forma
-- sistemática hasta octubre de 2026 (33 huérfanos, ver CLAUDE.md de
-- ranchos--app, sección "Reparación del DW"); el bug de código ya está
-- corregido (PR #157), este test es la red de seguridad para que el próximo
-- caso —de cualquier causa— se vea en la corrida nocturna en vez de
-- descubrirse meses después por una cifra que no cuadra.
--
-- Lee del source `ranchos_operacional` (ranchos-7c313, el DW en vivo) y no
-- de la réplica raw: la réplica se copia una vez al día y un huérfano
-- reparado entre copias seguiría apareciendo acá hasta la siguiente. Mismo
-- criterio que los tests de reconciliación (ver
-- tests/generic/test_reconciliacion_conteo_raw_vs_operacional.sql).
--
-- Solo las 9 tablas que versionan Activo/Corregido/Anulado. Quedan fuera
-- movimientos_insumos y periodos_consumo_insumos (ledger inmutable, su
-- estado_registro es siempre 'Activo') y las dim (edición in-place).
--
-- Reparación: scripts/reparar-huerfanos-dw.js en ranchos--app (--dry-run
-- primero). Equivalente manual de este test:
-- ranchos--app/scripts/detectar-huerfanos-dw.sql.
--
-- Falso positivo posible pero raro: si una corrección se está aplicando en
-- el instante exacto en que corre el test (entre el UPDATE a 'Corregido' y
-- el INSERT de la versión nueva, un par de segundos), aparecería como
-- huérfano y se resolvería solo en la siguiente corrida.
--
-- No depende de ningún modelo (solo de sources), así que si falla no hace
-- que dbt omita modelos downstream: el efecto es que la ejecución del Job
-- termina en error y las filas ofensoras quedan en metadata_ranchos.

{{ config(store_failures=true, schema='metadata_ranchos', severity='error') }}

with versiones as (

    select 'tb_fact_palpamientos' as tabla, id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_palpamientos') }}

    union all
    select 'tb_fact_partos', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_partos') }}

    union all
    select 'tb_fact_tratamientos', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_tratamientos') }}

    union all
    select 'tb_fact_pesaje_leche', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_pesaje_leche') }}

    union all
    select 'tb_fact_salidas', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_salidas') }}

    union all
    select 'tb_fact_transacciones_financieras', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_transacciones_financieras') }}

    union all
    select 'tb_fact_venta_leche', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_venta_leche') }}

    union all
    select 'tb_fact_microbiologia_leche', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_microbiologia_leche') }}

    union all
    select 'tb_fact_composicion_leche', id_registro, estado_registro
    from {{ source('ranchos_operacional', 'tb_fact_composicion_leche') }}

)

select
    tabla,
    id_registro,
    countif(estado_registro = 'Corregido') as versiones_corregidas

from versiones
group by tabla, id_registro
having countif(estado_registro = 'Corregido') > 0
   and countif(estado_registro in ('Activo', 'Anulado')) = 0
