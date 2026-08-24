#!/usr/bin/env python3
"""Barrida: detecta tablas del dataset raw que todavía no están declaradas
como source en _ranchos__sources.yml (y viceversa).

Por qué existe
--------------
RanchOS (el proyecto operacional) suma tablas nuevas seguido, cada vez que
se construye un módulo nuevo — y la réplica EL las copia sola a `ranchos`
(el Data Transfer es un "Dataset Copy" completo, no una lista fija de
tablas). Pero declararlas como source acá es un paso MANUAL: hasta que
alguien lo haga, esa tabla existe en el warehouse sin ningún test de
calidad, sin freshness y sin reconciliación contra la fuente — invisible
para todo el aparato de gobernanza (ver docs/dama_governance.md).

Este script es el chequeo explícito de ese desfasaje. Se corre a demanda,
cuando se sabe que se agregaron tablas nuevas al sistema operacional. No
corre dentro del pipeline programado a propósito: el pipeline debe fallar
por problemas de DATOS, no por una tabla nueva que todavía nadie tuvo
tiempo de modelar — eso es trabajo pendiente, no una alarma de producción.

Solo LEE. Nunca modifica _ranchos__sources.yml ni nada en BigQuery — emite
el bloque YAML sugerido para pegar a mano, para que la decisión de qué
monitorear y con qué columna de tiempo siga siendo explícita.

Uso
---
    python scripts/detectar_tablas_nuevas.py
    python scripts/detectar_tablas_nuevas.py --incluir-vistas

Código de salida: 0 si no hay desfasaje, 1 si encontró algo (así se puede
enganchar a un check manual/CI más adelante si alguna vez se decide).
"""

import argparse
import re
import sys

from google.cloud import bigquery

# La consola de Windows usa cp1252 por defecto y rompe los acentos/guiones
# largos de los mensajes. Forzar UTF-8 en la salida (no-op en Linux/macOS).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

PROYECTO_DEFAULT = "alba-analytics-ganaderia"
DATASET_DEFAULT = "ranchos"
SOURCES_DEFAULT = "models/staging/ranchos/_ranchos__sources.yml"

# Las tablas fact usan una columna TIMESTAMP real para bucketear las
# métricas de anomalías; las dim usan una columna DATE de alta que hay que
# castear para freshness. El orden importa: es el de preferencia al sugerir.
# Ver el comentario extenso de all_columns_anomalies en _ranchos__sources.yml.
CANDIDATAS_TIMESTAMP = ["timestamp_registro", "timestamp_evento"]
CANDIDATAS_FECHA = ["fecha_creacion", "fecha_registro"]


def tablas_declaradas(path):
    """Nombres declarados bajo el source `ranchos` en el YAML.

    Se parsea con regex sobre el bloque de ese source (no con un parser
    YAML completo) a propósito: alcanza para esta comparación y evita que
    el script se rompa si el YAML incorpora sintaxis de dbt que un
    safe_load no interpreta igual.
    """
    texto = open(path, encoding="utf-8").read()
    # Cortar antes del segundo source (ranchos_operacional): sus tablas son
    # las MISMAS de la fuente real, no del warehouse — contarlas duplicaría.
    corte = texto.find("name: ranchos_operacional")
    bloque = texto[:corte] if corte != -1 else texto
    return set(re.findall(r"^      - name: (\w+)", bloque, re.M))


def objetos_reales(client, proyecto, dataset):
    """{nombre: tipo} de todo lo que existe hoy en el dataset raw."""
    query = f"""
        SELECT table_name, table_type
        FROM `{proyecto}.{dataset}.INFORMATION_SCHEMA.TABLES`
    """
    return {fila.table_name: fila.table_type for fila in client.query(query).result()}


def columnas(client, proyecto, dataset, tabla):
    """{nombre_columna: tipo} de una tabla puntual."""
    query = f"""
        SELECT column_name, data_type
        FROM `{proyecto}.{dataset}.INFORMATION_SCHEMA.COLUMNS`
        WHERE table_name = @tabla
    """
    job = client.query(
        query,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("tabla", "STRING", tabla)]
        ),
    )
    return {fila.column_name: fila.data_type for fila in job.result()}


def sugerir_bloque(client, proyecto, dataset, tabla):
    """Bloque YAML sugerido para una tabla nueva, con su columna de tiempo
    REAL verificada contra INFORMATION_SCHEMA — nunca copiada de otra tabla
    (loaded_at_field no es uniforme, ver el comentario en el YAML)."""
    cols = columnas(client, proyecto, dataset, tabla)
    es_fact = "_fact_" in tabla

    ts = next((c for c in CANDIDATAS_TIMESTAMP if cols.get(c) == "TIMESTAMP"), None)
    fecha = next((c for c in CANDIDATAS_FECHA if c in cols), None)

    lineas = [f"      - name: {tabla}", "        config:"]

    if ts:
        lineas.append(f"          loaded_at_field: {ts}")
        col_tiempo = ts
    elif fecha:
        lineas.append(f'          loaded_at_field: "cast({fecha} as timestamp)"')
        col_tiempo = fecha
    else:
        lineas.append("          # TODO: sin columna de tiempo reconocida — revisar a mano")
        col_tiempo = None

    if es_fact:
        lineas += ["          freshness:", "            warn_after: {count: 5, period: day}",
                   "            error_after: {count: 14, period: day}"]

    lineas += [
        "        tests:",
        "          - reconciliacion_conteo_raw_vs_operacional:",
        "              arguments:",
        f"                tabla_operacional: source('ranchos_operacional', '{tabla}')",
    ]

    if col_tiempo:
        for test in ("volume_anomalies", "freshness_anomalies"):
            lineas += [
                f"          - elementary.{test}:",
                "              arguments:",
                f"                timestamp_column: {col_tiempo}",
                "              config:",
                "                tags: ['elementary']",
                "                severity: warn",
            ]
    # all_columns_anomalies SOLO en fact y SOLO con timestamp_column real —
    # ver el incidente documentado en el YAML y en docs/.
    if es_fact and ts:
        lineas += [
            "          - elementary.all_columns_anomalies:",
            "              arguments:",
            f"                timestamp_column: {ts}",
            "              config:",
            "                tags: ['elementary']",
            "                severity: warn",
        ]

    return "\n".join(lineas)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default=PROYECTO_DEFAULT)
    parser.add_argument("--dataset", default=DATASET_DEFAULT)
    parser.add_argument("--sources", default=SOURCES_DEFAULT)
    parser.add_argument(
        "--incluir-vistas",
        action="store_true",
        help="Incluir objetos VIEW en la comparación. Por defecto se ignoran: "
             "las VS_* del dataset raw son vistas legacy pre-dbt, no tablas "
             "replicadas por el pipeline EL.",
    )
    args = parser.parse_args()

    client = bigquery.Client(project=args.project)

    declaradas = tablas_declaradas(args.sources)
    reales = objetos_reales(client, args.project, args.dataset)

    if args.incluir_vistas:
        candidatas = dict(reales)
    else:
        candidatas = {n: t for n, t in reales.items() if t == "BASE TABLE"}

    vistas_ignoradas = sorted(n for n, t in reales.items() if t != "BASE TABLE")
    sin_declarar = sorted(n for n in candidatas if n not in declaradas)
    fantasma = sorted(d for d in declaradas if d not in reales)

    print(f"Dataset raw : {args.project}:{args.dataset}")
    print(f"Declarado en: {args.sources}")
    print()
    print(f"  objetos en el dataset       : {len(reales)}")
    print(f"  tablas consideradas         : {len(candidatas)}")
    print(f"  declaradas como source      : {len(declaradas)}")
    if vistas_ignoradas and not args.incluir_vistas:
        print(f"  vistas ignoradas            : {len(vistas_ignoradas)} "
              f"({', '.join(vistas_ignoradas)})")
    print()

    if not sin_declarar and not fantasma:
        print("OK — no hay desfasaje: todo lo que existe está declarado y viceversa.")
        return 0

    if sin_declarar:
        print(f"SIN DECLARAR ({len(sin_declarar)}) — existen en el warehouse pero")
        print("ningún test de calidad las cubre todavía:")
        for tabla in sin_declarar:
            print(f"  - {tabla}")
        print()
        print("Bloque(s) sugerido(s) para pegar en el YAML (revisar antes,")
        print("sobre todo la columna de tiempo y si la tabla amerita monitoreo):")
        print()
        for tabla in sin_declarar:
            print(sugerir_bloque(client, args.project, args.dataset, tabla))
            print()

    if fantasma:
        print(f"DECLARADAS PERO INEXISTENTES ({len(fantasma)}) — el source apunta a")
        print("algo que ya no está en el dataset (¿se renombró o se borró?):")
        for tabla in fantasma:
            print(f"  - {tabla}")
        print()

    return 1


if __name__ == "__main__":
    sys.exit(main())
