{#
  Fase 5 del documento de especificación — dimensión de calidad
  "Conciliación": compara el conteo de filas de una tabla en raw (L0,
  réplica en alba-analytics-ganaderia) contra la misma tabla en el source
  ranchos_operacional (ranchos-7c313, la fuente real). Responde
  directamente la pregunta "¿se copiaron todos los documentos de Firestore
  hasta acá?" — Firestore → ranchos-7c313 ya está cubierto por las Cloud
  Functions de sync de ranchos--app (fuera del alcance de este repo);
  ranchos-7c313 → raw es exactamente lo que este test verifica.

  tabla_operacional se pasa ya resuelto (`source('ranchos_operacional',
  '<tabla>')`) desde el YAML — mismo patrón que ya usa `relationships`
  (`to: source(...)`) en este mismo archivo. Un `model.identifier`
  computado dentro del macro y pasado a `source()` ahí adentro NO
  funciona: el analizador estático de dbt (que arma el grafo de
  dependencias en tiempo de parseo, sin ejecutar Jinja) no puede resolver
  un nombre de source dinámico — falla en silencio con un source
  "no encontrado" con un nombre mangled, no con un error claro.

  Falla (severidad error, ver docs/dama_governance.md sección 1) si los
  conteos no coinciden EXACTO — la réplica es un overwrite completo
  (BigQuery Data Transfer, ver infra/workflows/trigger_el_transfer.yaml),
  así que ambos lados deberían coincidir siempre salvo:
  1. Una escritura real ocurrió en el intervalo entre que este test corrió
     y la última sincronización 3x/día — falso positivo transitorio,
     desaparece solo en la próxima corrida.
  2. La sincronización realmente se rompió — el caso real que este test
     existe para atrapar.

  store_failures persiste el resultado en metadata_ranchos (Fase 5:
  "esa serie histórica es el insumo para reportar la evolución de la
  calidad del dato", no solo una alarma puntual).
#}

{% test reconciliacion_conteo_raw_vs_operacional(model, tabla_operacional) %}

{{ config(store_failures=true, schema='metadata_ranchos', severity='error') }}

with raw as (

    select count(*) as conteo_raw
    from {{ model }}

),

operacional as (

    select count(*) as conteo_operacional
    from {{ tabla_operacional }}

)

select
    raw.conteo_raw,
    operacional.conteo_operacional,
    raw.conteo_raw - operacional.conteo_operacional as diferencia

from raw
cross join operacional
where raw.conteo_raw != operacional.conteo_operacional

{% endtest %}
