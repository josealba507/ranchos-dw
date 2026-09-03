# Servidor MCP — preguntarle al warehouse en lenguaje natural

Expone las métricas de L4 (`rpt_ranchos`) a Claude Desktop como 6
herramientas de negocio. Diseño y justificación de cada decisión en
[`../docs/mcp_server.md`](../docs/mcp_server.md).

En una frase: el agente elige **qué** preguntar, nunca **cómo**
consultarlo. No hay una herramienta que reciba SQL.

## Instalación

Entorno propio, separado del de dbt a propósito: así una dependencia del
servidor no puede romper el pipeline que corre todas las noches.

```bash
python -m venv mcp/.venv
mcp/.venv/Scripts/pip install -r mcp/requirements.txt   # Linux/macOS: mcp/.venv/bin/pip
```

Autenticación por ADC, la misma que ya usa dbt en local:

```bash
gcloud auth application-default login
```

## Conectarlo a Claude Desktop

En `claude_desktop_config.json` (Windows:
`%APPDATA%\Claude\claude_desktop_config.json`, macOS:
`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "ranchos-dw": {
      "command": "C:\\ALBA_ANALYTICS\\GANADERIA\\dw_ranchos_app\\mcp\\.venv\\Scripts\\python.exe",
      "args": ["C:\\ALBA_ANALYTICS\\GANADERIA\\dw_ranchos_app\\mcp\\server.py"]
    }
  }
}
```

Reiniciar Claude Desktop después de editarlo.

## Preguntas de ejemplo

- *¿Cuántas vacas están preñadas y cuáles paren en los próximos 30 días?*
- *¿Qué vacas hay que palpar en el lote de ordeño?*
- *¿Hubo posibles abortos este año?*
- *¿Cómo viene el precio por litro de la leche en los últimos 6 meses?*
- *¿En qué categoría gastamos más en 2026?*

## Las 6 herramientas

| Herramienta | Grano | Rango de fechas |
|---|---|---|
| `consultar_entregas_leche` | una entrega | requerido |
| `consultar_estado_reproductivo` | una vaca activa palpada | no aplica |
| `consultar_vacas_a_palpar` | una vaca pendiente | no aplica |
| `consultar_transiciones_palpamiento` | un palpamiento | requerido |
| `consultar_finanzas_mensual` | finca + mes + tipo + categoría | requerido, en `AAAA-MM` |
| `consultar_existencia_insumos` | un insumo por finca | no aplica |

Tres no reciben rango de fechas porque consultan estado actual, donde un
rango no significa nada. Es consecuencia directa del grano declarado de
cada modelo, no una omisión.

## Sobre la seguridad en local

**Con ADC, el servidor corre con tus propias credenciales**, que en este
proyecto son de owner. O sea: en local, lo que impide alcanzar `marts` o
las tablas crudas son las **herramientas cerradas**, no el permiso IAM.

Para ejercer de verdad la frontera de permisos hay que correr como la
service account acotada (una vez creada, ver
[`../docs/bi_looker_studio.md`](../docs/bi_looker_studio.md) para el
patrón):

```bash
export RANCHOS_DW_IMPERSONATE_SA=mcp-agent-reader@alba-analytics-ganaderia.iam.gserviceaccount.com
```

Con esa variable el servidor impersona esa identidad y una consulta fuera
de `rpt_ranchos` fallaría con `accessDenied` — que es el comportamiento
que el diseño promete.

## Límites

500 filas, 24 meses de rango, 100 MB facturados por consulta.

**Al excederlos devuelve un error explícito; nunca entrega resultados
parciales.** Si truncara en silencio, el agente sumaría sobre datos
incompletos y reportaría el total con total confianza — un error
invisible para quien lee la respuesta.

## Qué NO hace

Solo lectura, y solo sobre `rpt_ranchos`. No escribe nada, no toca la
aplicación operacional, y no accede a marts, staging, snapshots ni a las
tablas fuente. Transporte stdio local: no hay nada desplegado ni expuesto
en red.
