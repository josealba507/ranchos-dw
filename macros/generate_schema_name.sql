{#
  Por defecto dbt concatena el schema custom al dataset default
  (ej. "dbt_default_marts"). Lo sobreescribimos para que
  `+schema: staging` / `+schema: marts` (definidos en dbt_project.yml)
  creen datasets limpios "staging" / "marts" en BigQuery, sin prefijo —
  necesario para que la regla de gobernanza "BI solo consulta el dataset
  marts" (docs/dama_governance.md, sección 5) sea un nombre de dataset
  real y no una convención informal.

  Separación de entornos (DAMA — Environment Management): en el target
  "dev" (el default de ~/.dbt/profiles.yml para trabajo local) se agrega
  el prefijo "dev_" a cada dataset, así un `dbt run` local nunca escribe
  sobre los datasets "de verdad" que algún día consuma BI. El target
  "prod" (reservado para cuando exista un pipeline/CI real) escribe sin
  prefijo.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set base_schema = custom_schema_name | trim if custom_schema_name is not none else target.schema -%}
    {%- if target.name == 'dev' -%}
        {{ 'dev_' ~ base_schema }}
    {%- else -%}
        {{ base_schema }}
    {%- endif -%}
{%- endmacro %}
