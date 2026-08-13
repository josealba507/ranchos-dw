-- Grano: una finca.
--
-- Dimensión conformada (docs/dama_governance.md sección 2) — compartida
-- por todos los dominios de negocio, por eso vive en marts/comun/ y no en
-- un dominio específico. Sin historización (Fase 4 del documento de
-- especificación: "sin historización, si el análisis no lo requiere") —
-- una finca no cambia de nombre/ubicación con frecuencia suficiente para
-- justificar SCD tipo 2.
select
    id_finca,
    nombre_finca,
    ubicacion,
    estado

from {{ ref('stg_ranchos__fincas') }}
