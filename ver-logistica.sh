#!/usr/bin/env bash
# Muestra los datos utiles de Logistica para una pregunta de demo:
# deposito, stock por producto, paquete, asignacion y metricas de cola.
#
# Uso:
#   ./ver-logistica.sh
#   ./ver-logistica.sh --producto <productoID> --detalle
#   ./ver-logistica.sh --deposito <depositoID> --paquete <paqueteID>
#   ./ver-logistica.sh --asignacion <asignacionID>
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"
exigir_json

DEPOSITO_ARG="${DEPOSITO:-}"
PRODUCTO_ARG="${PROD_STOCK:-${PRODUCTO:-}}"
ASIGNACION_ARG="${ASIGNACION:-}"
PAQUETE_ARG="${PAQUETE:-}"
DETALLE="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --deposito) [ $# -ge 2 ] || { echo "Falta valor para --deposito" >&2; exit 1; }
                DEPOSITO_ARG="$2"; shift 2 ;;
    --deposito=*) DEPOSITO_ARG="${1#*=}"; shift ;;
    --producto) [ $# -ge 2 ] || { echo "Falta valor para --producto" >&2; exit 1; }
                PRODUCTO_ARG="$2"; shift 2 ;;
    --producto=*) PRODUCTO_ARG="${1#*=}"; shift ;;
    --asignacion) [ $# -ge 2 ] || { echo "Falta valor para --asignacion" >&2; exit 1; }
                  ASIGNACION_ARG="$2"; shift 2 ;;
    --asignacion=*) ASIGNACION_ARG="${1#*=}"; shift ;;
    --paquete) [ $# -ge 2 ] || { echo "Falta valor para --paquete" >&2; exit 1; }
               PAQUETE_ARG="$2"; shift 2 ;;
    --paquete=*) PAQUETE_ARG="${1#*=}"; shift ;;
    --detalle) DETALLE="si"; shift ;;
    -h|--help|help|ayuda) ayuda --help ;;
    *) echo "Argumento desconocido: $1  (./ver-logistica.sh --help)" >&2; exit 1 ;;
  esac
done

leer_contador() {
  curl -sS -m "${METRICS_TIMEOUT:-12}" "$1/actuator/metrics/$2" 2>/dev/null \
    | sed -n 's/.*"value":\([0-9][0-9.]*\).*/\1/p' | head -1 | cut -d. -f1
}

titulo "LOGISTICA - ESTADO PARA DEMO"

paso "1. Totales"
req GET "$URL_LOGISTICA/admin/db/status"
if [ "$HTTP_CODE" = "200" ]; then
  printf "  depositos: %-6s paquetes: %-6s asignaciones: %s\n" \
    "$(campo '.depositos')" "$(campo '.paquetes')" "$(campo '.asignaciones')" >&2
  ok "estado general disponible"
else
  falla "no se pudo leer /admin/db/status (HTTP $HTTP_CODE)"
fi

if [ -n "$PRODUCTO_ARG" ]; then
  paso "2. Stock del producto"
  req GET "$URL_LOGISTICA/stock/$PRODUCTO_ARG"
  if [ "$HTTP_CODE" = "200" ]; then
    printf "  productoId:          %s\n" "$(campo '.productoId')" >&2
    printf "  cantidadDisponible:  %s\n" "$(campo '.cantidadDisponible')" >&2
    ok "stock consultado"
  else
    aviso "no se pudo leer stock/$PRODUCTO_ARG (HTTP $HTTP_CODE)"
  fi
fi

if [ -n "$DEPOSITO_ARG" ]; then
  paso "3. Deposito"
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO_ARG"
  if [ "$HTTP_CODE" = "200" ]; then
    DEPOSITO_JSON="$HTTP_BODY"
    printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
detalle = sys.argv[1] == "si"
paquete_buscado = sys.argv[2]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
stock = d.get("stockActual") or []
total = sum(int(x.get("cantidad") or 0) for x in stock)
did = d.get("id")
nombre = d.get("nombre")
algoritmo = d.get("algoritmo")
capacidad = d.get("capacidadMaxima")
print(f"  id:                {did}")
print(f"  nombre:            {nombre}")
print(f"  algoritmo:         {algoritmo}")
print(f"  capacidadMaxima:   {capacidad}")
print(f"  paquetes:          {len(stock)}")
print(f"  unidades cargadas: {total}")
if paquete_buscado:
    encontrados = [x for x in stock if str(x.get("id")) == str(paquete_buscado)]
    if encontrados:
        p = encontrados[0]
        pid = p.get("id")
        donacion = p.get("donacionID")
        producto = p.get("producto")
        cantidad = p.get("cantidad")
        print(f"  paquete buscado:   {pid} donacion={donacion} producto={producto} cantidad={cantidad}")
    else:
        print(f"  paquete buscado:   {paquete_buscado} no aparece en este deposito")
if detalle and stock:
    print("  stockActual:")
    for p in stock[-12:]:
        pid = p.get("id")
        donacion = p.get("donacionID")
        producto = p.get("producto")
        cantidad = p.get("cantidad")
        print(f"    paquete={pid}  donacion={donacion}  producto={producto}  cantidad={cantidad}")
' "$DETALLE" "$PAQUETE_ARG" >&2 2>/dev/null
    ok "deposito consultado"
  else
    aviso "no se pudo leer deposito/$DEPOSITO_ARG (HTTP $HTTP_CODE)"
  fi
fi

if [ -n "$ASIGNACION_ARG" ]; then
  paso "4. Asignacion"
  req GET "$URL_LOGISTICA/asignaciones/$ASIGNACION_ARG"
  if [ "$HTTP_CODE" = "200" ]; then
    printf "  id:                %s\n" "$(campo '.id')" >&2
    printf "  paqueteID:         %s\n" "$(campo '.paqueteID')" >&2
    printf "  necesidadID:       %s\n" "$(campo '.necesidadID')" >&2
    printf "  cantidadAsignada:  %s\n" "$(campo '.cantidadAsignada')" >&2
    printf "  estado:            %s\n" "$(campo '.estado')" >&2
    printf "  origen:            %s\n" "$(campo '.origen')" >&2
    ok "asignacion consultada"
  else
    aviso "no se pudo leer asignacion/$ASIGNACION_ARG (HTTP $HTTP_CODE)"
  fi
fi

paso "5. Cola de matchmaking"
PUB=$(leer_contador "$URL_LOGISTICA" "rabbitmq.published")
CONS=0
REJ=0
VIVOS=0
for wurl in "${URL_LOGISTICA_WORKER_1:-}" "${URL_LOGISTICA_WORKER_2:-}"; do
  [ -n "$wurl" ] || continue
  c=$(leer_contador "$wurl" "rabbitmq.consumed")
  r=$(leer_contador "$wurl" "rabbitmq.rejected")
  if [ -n "$c" ]; then CONS=$((CONS + c)); VIVOS=$((VIVOS + 1)); fi
  [ -n "$r" ] && REJ=$((REJ + r))
done
printf "  publicados API:     %s\n" "${PUB:-?}" >&2
printf "  consumidos workers: %s\n" "$CONS" >&2
printf "  rechazados workers: %s\n" "$REJ" >&2
printf "  workers vivos:      %s\n" "$VIVOS" >&2
if [ "$VIVOS" = "0" ]; then
  aviso "no hay workers respondiendo metricas"
elif [ "$REJ" != "0" ]; then
  aviso "hay mensajes rechazados por workers"
else
  ok "workers responden metricas"
fi

echo "" >&2
echo "  Para cambiar el algoritmo del deposito:" >&2
echo "    ./modificar-deposito.sh --deposito ${DEPOSITO_ARG:-<id>} --algoritmo PRIORIDAD_POR_SCORE" >&2
echo "  Para ver un estado puntual:" >&2
echo "    ./ver-estado.sh asignacion ${ASIGNACION_ARG:-<id>}" >&2

resumen
