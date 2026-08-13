{#
  Filtros de exclusión de datos de prueba/verificación de ranchos--app que
  quedaron en producción sin limpiar del todo (ver docs/fase0_inspeccion.md
  y docs/checkpoint2_movimientos_insumos.md). No es lógica de negocio real
  — es sanear basura técnica antes de que rompa los tests de integridad
  referencial contra dim_finca. Centralizado acá en vez de repetir los
  literales en cada modelo de staging, para tener un solo lugar que
  actualizar si aparece un nuevo caso.

  Dos patrones distintos según qué columna usa cada tabla fuente para
  referenciar la finca (ver docs/fase0_inspeccion.md, hallazgo de
  inconsistencia de nombres de columna — no todas las tablas son iguales):
  - Hato/Veterinaria/Insumos: columna `finca_asociada` (texto, nombre de
    la finca) — las fincas de prueba usan el prefijo "TEST-" de forma
    consistente.
  - Finanzas/Leche: columna `id_finca` (el id resuelto) — las fincas de
    prueba encontradas acá NO siguen un prefijo único
    (`finca_trebol`, `test-verificacion-venta-leche-finanzas`), así que
    se excluyen por lista explícita, confirmada con el usuario el
    2026-08-13 como datos de prueba propios, no producción real sin
    sincronizar.
#}

{% macro filtro_finca_prueba_por_nombre(columna='finca_asociada') %}
{{ columna }} not like 'TEST-%'
{% endmacro %}

{% macro filtro_finca_prueba_por_id(columna='id_finca') %}
{{ columna }} not in ('finca_trebol', 'test-verificacion-venta-leche-finanzas')
{% endmacro %}
