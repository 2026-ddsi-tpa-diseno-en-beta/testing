#!/usr/bin/env bash
# FLUJO E4 - PARCIALIDAD SEGUN EL TIPO DE NECESIDAD
#
# Cuando el stock no alcanza para cubrir toda la necesidad, el enunciado distingue por tipo:
#
#   EXTRAORDINARIA -> admite satisfaccion parcial, en varias instancias, hasta alcanzar o
#                     superar la cantidad objetivo. Se le asigna lo que haya.
#   RECURRENTE     -> NO admite parcial. Se tiene que cubrir en una unica entrega dentro del
#                     periodo, asi que con stock insuficiente no se le asigna nada.
#
# El script genera stock insuficiente y compara el comportamiento de los dos tipos con la
# misma cantidad, que es la unica forma de aislar la diferencia.
#
# Uso:  ./21-flujo-parcialidad-por-tipo.sh [stock] [--simular-worker]
set -u
. "$(dirname "$0")/lib/comun.sh"

STOCK_OBJETIVO="${1:-5}"
SIMULAR="no"
for arg in "$@"; do
  [ "$arg" = "--simular-worker" ] && SIMULAR="si"
done

exigir_estado DONADOR_OK
exigir_estado ENTIDAD
exigir_estado DEPOSITO
exigir_estado CATEGORIA

SELLO="$(date +%H%M%S)"
FALTANTE=$((STOCK_OBJETIVO + 10))

titulo "FLUJO E4 - PARCIALIDAD SEGUN TIPO DE NECESIDAD"
echo "Se genera stock de $STOCK_OBJETIVO unidades y se piden $FALTANTE."
echo "Esperado:  EXTRAORDINARIA acepta parcial  |  RECURRENTE no"

# --------------------------------------------------------- generar stock
generar_stock() {
  local etiqueta="$1" cantidad="$2"
  local subcat_field=""
  [ -n "${SUBCATEGORIA:-}" ] && subcat_field=",\"subcategoriaID\":\"$SUBCATEGORIA\""

  req POST "$URL_DONACIONES/productos" \
    "{\"nombre\":\"$PREFIJO Parc $etiqueta $SELLO\",\"descripcion\":\"producto para probar parcialidad\",\"categoriaID\":\"$CATEGORIA\"$subcat_field}"
  local prod
  prod=$(campo '.id')
  [ -z "$prod" ] || [ "$prod" = "null" ] && { echo ""; return; }

  req POST "$URL_DONACIONES/donaciones" \
    "{\"donadorID\":\"$DONADOR_OK\",\"depositoID\":\"$DEPOSITO\",\"descripcion\":\"$PREFIJO stock $etiqueta\",\"productoID\":\"$prod\",\"cantidad\":$cantidad}"
  local donacion
  donacion=$(campo '.id')

  sleep 15
  req GET "$URL_LOGISTICA/stock/$prod"
  local disponible
  disponible=$(campo '.cantidadDisponible')

  # Sin Worker el paquete queda PENDIENTE y nunca cuenta como stock.
  if [ "${disponible:-0}" = "0" ] && [ "$SIMULAR" = "si" ] && [ -n "$donacion" ]; then
    req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
    local paquete
    paquete=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('stockActual') or []:
    if p.get('donacionID') == '''${donacion}''':
        print(p.get('id')); break
" 2>/dev/null)
    if [ -n "$paquete" ]; then
      req POST "$URL_LOGISTICA/internal/matchmaking/resultados" \
        "{\"depositoId\":\"$DEPOSITO\",\"paqueteId\":\"$paquete\",\"necesidadId\":null,\"cantidadAsignada\":0,\"cantidadSobrante\":$cantidad}"
    fi
  fi
  echo "$prod"
}

# --------------------------------------------------- probar un tipo
probar_tipo() {
  local tipo="$1" producto="$2"

  paso "Stock disponible antes"
  req GET "$URL_LOGISTICA/stock/$producto"
  local stock_antes
  stock_antes=$(campo '.cantidadDisponible')
  detalle "stock: ${stock_antes:-0}"

  if [ "${stock_antes:-0}" = "0" ]; then
    aviso "sin stock, no se puede evaluar $tipo"
    echo "0|0|sin-stock"
    return
  fi

  paso "Crear necesidad $tipo pidiendo $FALTANTE (mas de lo que hay)"
  req POST "$URL_DONADORES/necesidades" \
    "{\"entidadID\":\"$ENTIDAD\",\"productoSolicitadoID\":\"$producto\",\"descripcion\":\"$PREFIJO parcialidad $tipo\",\"cantidadObjetivo\":$FALTANTE,\"nivelDeUrgencia\":7,\"tipo\":\"$tipo\"}"
  local codigo="$HTTP_CODE"

  sleep 3
  req GET "$URL_LOGISTICA/stock/$producto"
  local stock_despues
  stock_despues=$(campo '.cantidadDisponible')
  detalle "stock despues: ${stock_despues:-0}  (HTTP de la necesidad: $codigo)"

  local asignado=$((${stock_antes:-0} - ${stock_despues:-0}))
  detalle "unidades asignadas desde stock: $asignado"
  echo "${stock_antes:-0}|$asignado|$codigo"
}

# ============================================================ EXTRAORDINARIA
titulo "CASO A - Necesidad EXTRAORDINARIA con stock insuficiente"
detalle "el enunciado permite satisfacerla de forma parcial y en varias instancias"

PROD_A=$(generar_stock "extra" "$STOCK_OBJETIVO")
if [ -z "$PROD_A" ]; then
  falla "no se pudo preparar el producto para el caso A"; resumen; exit 1
fi
detalle "producto: $PROD_A"

RES_A=$(probar_tipo "EXTRAORDINARIA" "$PROD_A")
STOCK_A=$(printf '%s' "$RES_A" | cut -d'|' -f1)
ASIGNADO_A=$(printf '%s' "$RES_A" | cut -d'|' -f2)

if [ "$STOCK_A" = "0" ]; then
  aviso "el caso A no se pudo evaluar por falta de stock"
elif [ "$ASIGNADO_A" -gt 0 ]; then
  ok "EXTRAORDINARIA recibio una asignacion parcial de $ASIGNADO_A de $FALTANTE"
  [ "$ASIGNADO_A" = "$STOCK_A" ] \
    && ok "se asigno todo el stock disponible, que es lo esperado" \
    || aviso "se asigno $ASIGNADO_A de $STOCK_A disponibles"
else
  falla "EXTRAORDINARIA no recibio nada, y el enunciado permite parcial"
fi

# ============================================================ RECURRENTE
titulo "CASO B - Necesidad RECURRENTE con stock insuficiente"
detalle "el enunciado NO permite parcial: se cubre en una unica entrega o no se cubre"

PROD_B=$(generar_stock "recur" "$STOCK_OBJETIVO")
if [ -z "$PROD_B" ]; then
  falla "no se pudo preparar el producto para el caso B"; resumen; exit 1
fi
detalle "producto: $PROD_B"

RES_B=$(probar_tipo "RECURRENTE" "$PROD_B")
STOCK_B=$(printf '%s' "$RES_B" | cut -d'|' -f1)
ASIGNADO_B=$(printf '%s' "$RES_B" | cut -d'|' -f2)

if [ "$STOCK_B" = "0" ]; then
  aviso "el caso B no se pudo evaluar por falta de stock"
elif [ "$ASIGNADO_B" -eq 0 ]; then
  ok "RECURRENTE no recibio asignacion parcial, que es lo correcto"
else
  falla "RECURRENTE recibio $ASIGNADO_B unidades y no admite parcialidad"
  detalle "el enunciado dice que se cubre en una unica entrega dentro del periodo"
fi

# ============================================================ comparacion
titulo "COMPARACION"
printf "  %-16s %-8s %-12s %s\n" "TIPO" "STOCK" "ASIGNADO" "ESPERADO"
printf "  %-16s %-8s %-12s %s\n" "----" "-----" "--------" "--------"
printf "  %-16s %-8s %-12s %s\n" "EXTRAORDINARIA" "$STOCK_A" "$ASIGNADO_A" "parcial permitido"
printf "  %-16s %-8s %-12s %s\n" "RECURRENTE"     "$STOCK_B" "$ASIGNADO_B" "0 (sin parcial)"
echo ""

if [ "$STOCK_A" != "0" ] && [ "$STOCK_B" != "0" ]; then
  if [ "$ASIGNADO_A" -gt 0 ] && [ "$ASIGNADO_B" -eq 0 ]; then
    ok "los dos tipos se comportan distinto, como pide el enunciado"
  else
    falla "los dos tipos se comportan igual: la distincion por tipo no esta implementada"
  fi
fi

resumen
