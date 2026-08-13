{#
  Corrige mojibake de UTF-8 mal re-codificado como Latin-1 (ej. "PreÃ±ada"
  en vez de "Preñada") encontrado en producción real en tb_fact_palpamientos
  (resultado: 192/234 filas afectadas) y tb_fact_pesaje_leche (ordeno:
  53/128 filas afectadas) al construir el dominio Veterinaria — ver
  docs/fase0_inspeccion.md / PR de Veterinaria.

  Origen probable: el backfill histórico inicial desde Excel
  (backfill-hato-alba-guerra.js, ver CLAUDE.md de ranchos--app) no manejó
  bien el encoding de caracteres acentuados al escribir a Firestore. Los
  registros capturados después, vía la app real, están correctamente
  codificados — por eso conviven las 2 formas para el mismo valor de
  negocio en la misma columna.

  No se corrige en ranchos-7c313 (requeriría un UPDATE de producción con
  confirmación explícita, fuera de alcance de este repo) — se normaliza acá,
  en staging, para que marts/reporting no traten "Preñada" y "PreÃ±ada"
  como 2 valores de negocio distintos.

  Cobertura: los 5 caracteres acentuados españoles más comunes. Si aparece
  un nuevo caso (otro campo, otro caracter), agregar la línea REPLACE acá
  — no repetir la lógica por modelo.
#}

{% macro normalizar_mojibake(columna) %}
replace(replace(replace(replace(replace(
    {{ columna }},
    'Ã±', 'ñ'), 'Ã­', 'í'), 'Ã³', 'ó'), 'Ã©', 'é'), 'Ã¡', 'á')
{% endmacro %}
