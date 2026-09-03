"""Servidor MCP sobre la capa de métricas (L4) del warehouse.

Diseño completo y su justificación en docs/mcp_server.md. Lo esencial:

- Herramientas de negocio CERRADAS, no una que reciba SQL. El agente elige
  QUÉ preguntar, nunca CÓMO consultarlo. La razón principal no es el costo
  sino la consistencia: la capa de métricas existe para que "resultado
  neto" o "días abiertos" signifiquen una sola cosa, y con SQL abierto el
  agente inventaría su propia versión en cada consulta.
- Solo lectura, y solo sobre rpt_ranchos. Ninguna herramienta puede
  alcanzar marts, staging, snapshots ni las tablas crudas: el conjunto de
  vistas consultables está fijo acá abajo y se audita leyéndolo.
- Nunca trunca en silencio. Si una consulta excede un límite, devuelve un
  error explicando cuál — ver el comentario en _ejecutar().

Las descripciones de cada herramienta salen de las `description` de los
modelos en los YAML de dbt. Se reutilizan a propósito en vez de redactar
una segunda versión: dos textos que explican lo mismo se desincronizan.
"""

from __future__ import annotations

import os
from datetime import date, datetime
from typing import Any, Literal

from google.cloud import bigquery
from mcp.server.mcpserver import MCPServer

# --- Configuración -------------------------------------------------------

PROYECTO = os.environ.get("RANCHOS_DW_PROJECT", "alba-analytics-ganaderia")
DATASET = "rpt_ranchos"

# Impersonar la service account de solo-lectura (mcp-agent-reader) en vez de
# usar las credenciales propias. OJO: sin esto, en local ADC resuelve a las
# credenciales del desarrollador, que en este proyecto son de owner — o sea
# que la frontera de L4 la sostienen las herramientas cerradas, NO el IAM.
# Con la variable puesta, el servidor corre de verdad como la identidad
# acotada y el límite de permisos se ejerce en serio.
IMPERSONAR_SA = os.environ.get("RANCHOS_DW_IMPERSONATE_SA")

MAX_FILAS = 500
MAX_MESES_RANGO = 24
MAX_BYTES_FACTURADOS = 100 * 1024 * 1024  # 100 MB


class LimiteExcedido(Exception):
    """La consulta superó un límite. Se reporta, nunca se trunca callado."""


# --- Cliente de BigQuery -------------------------------------------------

_cliente: bigquery.Client | None = None


def _obtener_cliente() -> bigquery.Client:
    global _cliente
    if _cliente is not None:
        return _cliente

    if IMPERSONAR_SA:
        import google.auth
        from google.auth import impersonated_credentials

        origen, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        credenciales = impersonated_credentials.Credentials(
            source_credentials=origen,
            target_principal=IMPERSONAR_SA,
            target_scopes=["https://www.googleapis.com/auth/bigquery"],
        )
        _cliente = bigquery.Client(project=PROYECTO, credentials=credenciales)
    else:
        _cliente = bigquery.Client(project=PROYECTO)

    return _cliente


# --- Ejecución acotada ---------------------------------------------------

def _ejecutar(
    vista: str,
    columnas: list[str],
    condiciones: list[str],
    parametros: list[bigquery.ScalarQueryParameter],
    orden: str,
) -> dict[str, Any]:
    """Ejecuta una consulta armada por el servidor, no por el agente.

    `vista`, `columnas`, `condiciones` y `orden` los fija el código de cada
    herramienta; del agente solo llegan VALORES, y viajan como parámetros
    de consulta (nunca interpolados en el SQL). Es lo que hace que un
    argumento hostil no pueda cambiar la forma de la consulta.
    """
    where = f"where {' and '.join(condiciones)}" if condiciones else ""

    # Se pide UNA fila más que el máximo: si vuelve, sabemos que había más
    # de las que caben y podemos avisar en vez de entregar un subconjunto
    # que el agente sumaría creyendo que es el total.
    sql = f"""
        select {', '.join(columnas)}
        from `{PROYECTO}.{DATASET}.{vista}`
        {where}
        order by {orden}
        limit {MAX_FILAS + 1}
    """

    config = bigquery.QueryJobConfig(
        query_parameters=parametros,
        maximum_bytes_billed=MAX_BYTES_FACTURADOS,
    )

    filas = [dict(f) for f in _obtener_cliente().query(sql, job_config=config).result()]

    if len(filas) > MAX_FILAS:
        raise LimiteExcedido(
            f"La consulta devuelve más de {MAX_FILAS} filas. No se entregan "
            f"resultados parciales porque un total calculado sobre ellos "
            f"sería incorrecto sin que se note. Acotá el rango de fechas o "
            f"agregá un filtro (por finca, categoría o estado) y repetí."
        )

    # Los tipos DATE/NUMERIC de BigQuery no son serializables a JSON tal
    # cual; se pasan a texto y número respectivamente.
    for fila in filas:
        for clave, valor in fila.items():
            if isinstance(valor, (date, datetime)):
                fila[clave] = valor.isoformat()
            elif hasattr(valor, "as_tuple"):  # decimal.Decimal (NUMERIC)
                fila[clave] = float(valor)

    return {"filas": len(filas), "datos": filas}


def _validar_rango(desde: str, hasta: str) -> tuple[date, date]:
    try:
        d = date.fromisoformat(desde)
        h = date.fromisoformat(hasta)
    except ValueError as e:
        raise LimiteExcedido(f"Fecha inválida, se espera formato AAAA-MM-DD: {e}")

    if h < d:
        raise LimiteExcedido(f"'hasta' ({hasta}) es anterior a 'desde' ({desde}).")

    meses = (h.year - d.year) * 12 + (h.month - d.month)
    if meses > MAX_MESES_RANGO:
        raise LimiteExcedido(
            f"El rango pedido abarca ~{meses} meses y el máximo son "
            f"{MAX_MESES_RANGO}. Consultá por partes."
        )
    return d, h


def _validar_anio_mes(valor: str, nombre: str) -> int:
    """Convierte 'AAAA-MM' al entero AAAAMM que usan las comparaciones.

    Rechaza una fecha completa ('2026-07-01') en vez de interpretarla como
    su mes. Aceptarla sería peor que fallar: el agente creería haber
    filtrado a un día puntual y recibiría el mes entero, sin ninguna señal
    de que el filtro no era el que pidió.
    """
    partes = valor.split("-")
    if len(partes) != 2:
        raise LimiteExcedido(
            f"'{nombre}' debe tener formato AAAA-MM (por ejemplo 2026-07). "
            f"Esta métrica tiene grano MENSUAL, no diario — no acepta una "
            f"fecha completa. Se recibió: {valor!r}"
        )
    try:
        anio, mes = int(partes[0]), int(partes[1])
        if not 1 <= mes <= 12:
            raise ValueError("mes fuera de rango")
        if not 2000 <= anio <= 2100:
            raise ValueError("año fuera de rango")
        return anio * 100 + mes
    except ValueError:
        raise LimiteExcedido(
            f"'{nombre}' debe tener formato AAAA-MM (por ejemplo 2026-07); "
            f"se recibió: {valor!r}"
        )


def _texto(nombre: str, valor: str) -> bigquery.ScalarQueryParameter:
    return bigquery.ScalarQueryParameter(nombre, "STRING", valor)


# --- Servidor ------------------------------------------------------------

servidor = MCPServer(
    name="ranchos-dw",
    instructions=(
        "Consulta las métricas de negocio de una finca ganadera: producción "
        "y precio de la leche, estado reproductivo del hato, finanzas e "
        "inventario de insumos. Cada herramienta consulta una vista con un "
        "grano definido; las respuestas son filas a ese grano, y agregarlas "
        "es tarea tuya. Si una consulta excede el límite de filas vas a "
        "recibir un error: acotá el rango en vez de asumir que no hay datos."
    ),
)


@servidor.tool()
def consultar_entregas_leche(
    desde: str,
    hasta: str,
    finca: str | None = None,
) -> dict[str, Any]:
    """Entregas de leche, una fila por entrega (liquidación pagada por el
    comprador a una finca). Sirve para analizar cuánta leche se entrega,
    cuánto se cobra por ella y cómo evoluciona el precio por litro.

    IMPORTANTE: la fecha es la de PAGO, no la de ordeño. No usar esta
    herramienta para medir estacionalidad productiva.

    Para saber si el precio sube o baja, la columna es valor_litro_total.
    Los montos están en la moneda local de la finca.

    Args:
        desde: fecha inicial de pago, formato AAAA-MM-DD.
        hasta: fecha final de pago, formato AAAA-MM-DD.
        finca: nombre exacto de la finca. Si se omite, incluye todas.
    """
    d, h = _validar_rango(desde, hasta)
    condiciones = ["fecha_pago between @desde and @hasta"]
    parametros: list[bigquery.ScalarQueryParameter] = [
        bigquery.ScalarQueryParameter("desde", "DATE", d),
        bigquery.ScalarQueryParameter("hasta", "DATE", h),
    ]
    if finca:
        condiciones.append("nombre_finca = @finca")
        parametros.append(_texto("finca", finca))

    return _ejecutar(
        vista="rpt_metrica_entrega_leche",
        columnas=[
            "fecha_pago", "anio", "mes", "estacion", "nombre_finca",
            "litros_entrega", "valor_entrega_bruta", "incentivo_valor",
            "multa", "valor_entrega_neta", "valor_litro_base",
            "valor_litro_incentivo", "valor_litro_total",
        ],
        condiciones=condiciones,
        parametros=parametros,
        orden="fecha_pago desc",
    )


@servidor.tool()
def consultar_estado_reproductivo(
    finca: str | None = None,
    estado: Literal["Preñada", "Parió", "Vacía Ciclando", "Vacía Anestro"] | None = None,
    lote: str | None = None,
) -> dict[str, Any]:
    """Estado reproductivo ACTUAL del hato: una fila por vaca activa que
    tenga al menos un palpamiento. Responde cuántas están preñadas,
    cuántas vacías, hace cuánto no se palpan y cuántos días lleva abierta
    cada una. Para las preñadas incluye la fecha esperada de parto y la
    fecha de paso a preparto.

    No recibe rango de fechas: es una foto del presente.

    Sobre los estados: 'Preñada' es confirmada y todavía no parió; 'Parió'
    significa que su último palpamiento decía preñada pero ya dio a luz, o
    sea que hoy NO está preñada; 'Vacía Anestro' es la que más atención
    requiere, porque ni siquiera está ciclando.

    dias_abiertos es el indicador central de eficiencia reproductiva:
    mientras más alto, más tiempo lleva la vaca sin producir una cría.

    Solo incluye vacas ya palpadas. Las que nunca se palparon quedan fuera
    a propósito, así que este NO es el conteo total del hato.

    Args:
        finca: nombre exacto de la finca. Si se omite, incluye todas.
        estado: filtra por estado reproductivo.
        lote: lote de manejo.
    """
    condiciones: list[str] = []
    parametros: list[bigquery.ScalarQueryParameter] = []
    for nombre, valor, columna in (
        ("finca", finca, "nombre_finca"),
        ("estado", estado, "estado_reproductivo"),
        ("lote", lote, "lote"),
    ):
        if valor:
            condiciones.append(f"{columna} = @{nombre}")
            parametros.append(_texto(nombre, valor))

    return _ejecutar(
        vista="rpt_metrica_estado_reproductivo",
        columnas=[
            "nombre_finca", "lote", "arete", "estado_reproductivo",
            "fecha_ultimo_palpamiento", "dias_desde_ultimo_palpamiento",
            "fecha_ultimo_parto", "dias_desde_ultimo_parto", "dias_abiertos",
            "fecha_parto_esperada", "fecha_preparto", "dias_para_parto",
            "meses_atraso",
        ],
        condiciones=condiciones,
        parametros=parametros,
        orden="nombre_finca, lote, arete",
    )


@servidor.tool()
def consultar_vacas_a_palpar(
    finca: str | None = None,
    lote: str | None = None,
) -> dict[str, Any]:
    """Lista de trabajo: qué vacas hay que palpar. Incluye vacas activas no
    preñadas que ya pasaron el período de espera después del parto, o cuyo
    último palpamiento las dejó vacías.

    No recibe rango de fechas: es la lista pendiente de hoy. Viene ordenada
    por lote, que es el orden en que conviene recorrer el campo.

    dias_abiertos_aprox es una definición operativa de esta finca (días
    desde el parto menos el período de espera voluntario), distinta del
    'días abiertos' estándar de la industria — no compararla contra
    referencias externas.

    Args:
        finca: nombre exacto de la finca. Si se omite, incluye todas.
        lote: lote de manejo.
    """
    condiciones: list[str] = []
    parametros: list[bigquery.ScalarQueryParameter] = []
    for nombre, valor, columna in (
        ("finca", finca, "nombre_finca"),
        ("lote", lote, "lote"),
    ):
        if valor:
            condiciones.append(f"{columna} = @{nombre}")
            parametros.append(_texto(nombre, valor))

    # fecha_palpamiento_nuevo / resultado_palpamiento_nuevo se omiten a
    # propósito: son columnas de captura en campo, siempre nulas, y
    # devolverlas solo invitaría a explicar por qué están vacías.
    return _ejecutar(
        vista="rpt_vacas_a_palpar",
        columnas=[
            "nombre_finca", "lote", "arete", "chip", "fecha_ultimo_parto",
            "dias_desde_ultimo_parto", "dias_abiertos_aprox",
            "fecha_ultimo_palpamiento", "dias_desde_ultimo_palpamiento",
            "resultado_ultimo_palpamiento",
        ],
        condiciones=condiciones,
        parametros=parametros,
        orden="nombre_finca, lote, dias_desde_ultimo_parto desc",
    )


@servidor.tool()
def consultar_transiciones_palpamiento(
    desde: str,
    hasta: str,
    finca: str | None = None,
    transicion: Literal[
        "Primer palpamiento", "Mejoró", "Mantiene", "Empeoró", "Ciclo completado"
    ] | None = None,
    solo_posibles_abortos: bool = False,
) -> dict[str, Any]:
    """Evolución reproductiva entre palpamientos consecutivos: una fila por
    palpamiento, comparada contra el anterior de la misma vaca. Responde
    cuántas mejoraron, se mantuvieron o empeoraron, y en cuántos días.

    El orden reproductivo es: Vacía Anestro (peor) < Vacía Ciclando <
    Preñada (mejor).

    Distinción importante: 'Ciclo completado' es una vaca que estaba
    preñada y PARIÓ, así que aparecer vacía después es lo esperado, no una
    pérdida. 'Empeoró' con posible_aborto=true es la que perdió la preñez
    sin parir. Confundirlas haría reportar vacas sanas como problemas.

    Args:
        desde: fecha inicial de palpamiento, formato AAAA-MM-DD.
        hasta: fecha final de palpamiento, formato AAAA-MM-DD.
        finca: nombre exacto de la finca. Si se omite, incluye todas.
        transicion: filtra por tipo de transición.
        solo_posibles_abortos: si es true, devuelve solo las preñeces
            perdidas sin parto de por medio.
    """
    d, h = _validar_rango(desde, hasta)
    condiciones = ["fecha_palpamiento between @desde and @hasta"]
    parametros: list[bigquery.ScalarQueryParameter] = [
        bigquery.ScalarQueryParameter("desde", "DATE", d),
        bigquery.ScalarQueryParameter("hasta", "DATE", h),
    ]
    if finca:
        condiciones.append("nombre_finca = @finca")
        parametros.append(_texto("finca", finca))
    if transicion:
        condiciones.append("transicion = @transicion")
        parametros.append(_texto("transicion", transicion))
    if solo_posibles_abortos:
        condiciones.append("posible_aborto")

    return _ejecutar(
        vista="rpt_metrica_transicion_palpamiento",
        columnas=[
            "nombre_finca", "arete_animal", "fecha_palpamiento", "resultado",
            "fecha_palpamiento_previo", "resultado_previo",
            "dias_entre_palpamientos", "transicion", "detalle_transicion",
            "posible_aborto", "es_ultimo_palpamiento",
        ],
        condiciones=condiciones,
        parametros=parametros,
        orden="fecha_palpamiento desc",
    )


@servidor.tool()
def consultar_finanzas_mensual(
    desde: str,
    hasta: str,
    finca: str | None = None,
    tipo_transaccion: Literal["Entrada", "Salida", "Inversion"] | None = None,
    categoria: str | None = None,
) -> dict[str, Any]:
    """Finanzas agregadas por mes: una fila por finca, mes, tipo de
    transacción, categoría y clase. Responde en qué se gasta el dinero,
    cuánto entra y cómo evoluciona el resultado mes a mes.

    CRÍTICO: para sumar dinero usar SIEMPRE resultado_neto, que trae el
    signo (positivo si entró, negativo si salió). La columna monto_total
    NO tiene signo y sumarla mezcla ingresos con gastos, dando un número
    sin significado.

    Sobre los tipos: 'Entrada' es dinero que ingresa; 'Salida' es un gasto;
    'Inversion' es una compra de capital. Para el flujo de caja, Salida e
    Inversion restan por igual.

    Args:
        desde: mes inicial, formato AAAA-MM (por ejemplo 2026-01).
        hasta: mes final, formato AAAA-MM.
        finca: nombre exacto de la finca. Si se omite, incluye todas.
        tipo_transaccion: filtra por dirección del dinero.
        categoria: categoría de negocio del catálogo de finanzas.
    """
    d = _validar_anio_mes(desde, "desde")
    h = _validar_anio_mes(hasta, "hasta")
    if h < d:
        raise LimiteExcedido(f"'hasta' ({hasta}) es anterior a 'desde' ({desde}).")
    meses = (h // 100 - d // 100) * 12 + (h % 100 - d % 100)
    if meses > MAX_MESES_RANGO:
        raise LimiteExcedido(
            f"El rango pedido abarca {meses} meses y el máximo son "
            f"{MAX_MESES_RANGO}. Consultá por partes."
        )

    condiciones = ["anio * 100 + mes between @desde and @hasta"]
    parametros: list[bigquery.ScalarQueryParameter] = [
        bigquery.ScalarQueryParameter("desde", "INT64", d),
        bigquery.ScalarQueryParameter("hasta", "INT64", h),
    ]
    if finca:
        condiciones.append("nombre_finca = @finca")
        parametros.append(_texto("finca", finca))
    if tipo_transaccion:
        condiciones.append("tipo_transaccion = @tipo")
        parametros.append(_texto("tipo", tipo_transaccion))
    if categoria:
        condiciones.append("categoria = @categoria")
        parametros.append(_texto("categoria", categoria))

    return _ejecutar(
        vista="rpt_metrica_finanzas_mensual",
        columnas=[
            "anio", "mes", "mes_nombre", "estacion", "nombre_finca",
            "tipo_transaccion", "categoria", "clase", "cantidad_transacciones",
            "monto_total", "resultado_neto",
        ],
        condiciones=condiciones,
        parametros=parametros,
        orden="anio desc, mes desc, nombre_finca, categoria",
    )


@servidor.tool()
def consultar_existencia_insumos(
    finca: str | None = None,
    categoria: str | None = None,
    solo_negativos: bool = False,
) -> dict[str, Any]:
    """Existencia actual de cada insumo, calculada sumando el ledger
    completo de movimientos. Responde cuánto stock hay hoy y cuánto se ha
    gastado comprando cada insumo.

    No recibe rango de fechas: es un saldo, no una serie temporal.

    Las cantidades solo son comparables entre insumos que comparten la
    misma unidad de medida.

    existencia_negativa=true marca un saldo por debajo de cero, que es
    físicamente imposible y delata un movimiento mal capturado (una merma
    mayor al stock real, o una compra que nunca se registró).

    Args:
        finca: nombre exacto de la finca. Si se omite, incluye todas.
        categoria: categoría del insumo.
        solo_negativos: si es true, devuelve solo los insumos con
            existencia imposible, para revisarlos.
    """
    condiciones: list[str] = []
    parametros: list[bigquery.ScalarQueryParameter] = []
    for nombre, valor, columna in (
        ("finca", finca, "nombre_finca"),
        ("categoria", categoria, "categoria"),
    ):
        if valor:
            condiciones.append(f"{columna} = @{nombre}")
            parametros.append(_texto(nombre, valor))
    if solo_negativos:
        condiciones.append("existencia_negativa")

    return _ejecutar(
        vista="rpt_metrica_existencia_insumo",
        columnas=[
            "nombre_finca", "insumo_nombre", "categoria", "unidad",
            "existencia_actual", "cantidad_movimientos", "costo_total_comprado",
            "ultimo_movimiento", "existencia_negativa",
        ],
        condiciones=condiciones,
        parametros=parametros,
        orden="nombre_finca, insumo_nombre",
    )


if __name__ == "__main__":
    servidor.run(transport="stdio")
