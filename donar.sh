#!/usr/bin/env bash
# Registra donaciones con los parametros que quieras. Es la version manejable del flujo:
# el 10-flujo-registrar-donacion.sh hace un caso fijo y ya probado; este te deja elegir
# donador, producto, deposito, cantidad y cuantas donaciones hacer.
#
# Uso:
#   ./donar.sh
#       te pregunta todo, mostrandote los donadores y productos que hay
#
#   ./donar.sh --cantidad 40
#       una donacion de 40 unidades, con el donador y producto del .estado
#
#   ./donar.sh --veces 10 --cantidad 5
#       10 donaciones de 5 unidades cada una
#
#   ./donar.sh --veces 5 --cantidad 10 --incremental
#       5 donaciones de 10, 20, 30, 40 y 50 unidades
#       (sirve para la mision DONACIONES_ASCENDENTES, que pide 5 en tendencia creciente)
#
#   ./donar.sh --donador abc --producto 9 --deposito 10 --cantidad 60
#
#   ./donar.sh --veces 3 --cantidad 60 --sin-esperar
#       no espera al worker entre donaciones (mas rapido, menos verificacion)
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

DONADOR_ARG=""; PRODUCTO_ARG=""; DEPOSITO_ARG=""; CANTIDAD=""
VECES="1"; INCREMENTAL="no"; ESPERAR="si"

while [ $# -gt 0 ]; do
  case "$1" in
    --donador)      DONADOR_ARG="$2"; shift 2 ;;
    --producto)     PRODUCTO_ARG="$2"; shift 2 ;;
    --deposito)     DEPOSITO_ARG="$2"; shift 2 ;;
    --cantidad)     CANTIDAD="$2"; shift 2 ;;
    --veces)        VECES="$2"; shift 2 ;;
    --incremental)  INCREMENTAL="si"; shift ;;
    --sin-esperar)  ESPERAR="no"; shift ;;
    *) echo "Argumento desconocido: $1  (./donar.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "REGISTRAR DONACIONES"

# ------------------------------------------------ elegir los datos
if [ -t 0 ] && { [ -z "$DONADOR_ARG" ] || [ -z "$PRODUCTO_ARG" ]; }; then
  if [ -z "$DONADOR_ARG" ]; then
    req GET "$URL_DONADORES/donadores" >/dev/null 2>&1
    detalle "donadores que existen (ojo con el estado: un BANEADO no puede donar):"
    printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d[-8:]:
    print('    ' + str(x.get('id'))[:38] + '  ' + str(x.get('nombre'))[:18] + '  ' + str(x.get('estado')))
" >&2 2>/dev/null
  fi
  if [ -z "$PRODUCTO_ARG" ]; then
    req GET "$URL_DONACIONES/productos" >/dev/null 2>&1
    detalle "productos que existen:"
    printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d[-8:]: print('    ' + str(x.get('id')) + '  ' + str(x.get('nombre')))
" >&2 2>/dev/null
  fi
fi

preguntar DONADOR_ARG  "ID del donador"    "${DONADOR_OK:-}"
preguntar PRODUCTO_ARG "ID del producto"   "${PRODUCTO:-}"
preguntar DEPOSITO_ARG "ID del deposito"   "${DEPOSITO:-}"
preguntar CANTIDAD     "Cantidad a donar"  "10"
preguntar VECES        "Cuantas donaciones" "1"

echo "" >&2
detalle "donador:  $DONADOR_ARG"
detalle "producto: $PRODUCTO_ARG"
detalle "deposito: $DEPOSITO_ARG"
if [ "$INCREMENTAL" = "si" ]; then
  SEC=""
  i=1
  while [ "$i" -le "$VECES" ]; do SEC="$SEC $((CANTIDAD * i))"; i=$((i + 1)); done
  detalle "cantidades:$SEC  (incremental)"
else
  detalle "cantidades: $VECES donacion(es) de $CANTIDAD unidades"
fi

# ------------------------------------------------ chequeos previos
paso "Chequeos previos"
req GET "$URL_DONADORES/donadores/$DONADOR_ARG" >/dev/null 2>&1
if [ "$HTTP_CODE" = "200" ]; then
  ESTADO_DONADOR=$(campo '.estado')
  detalle "estado del donador: $ESTADO_DONADOR"
  case "$ESTADO_DONADOR" in
    BANEADO)    falla "el donador esta BANEADO: Donaciones va a rechazar todo"
                resumen; exit 1 ;;
    SOSPECHOSO) aviso "el donador es SOSPECHOSO: solo puede donar el 50% de las veces"
                detalle "es esperable que algunas de estas donaciones sean rechazadas" ;;
    *)          ok "el donador puede donar" ;;
  esac
else
  aviso "no se pudo leer el donador (HTTP $HTTP_CODE)"
fi

req GET "$URL_DONACIONES/productos/$PRODUCTO_ARG" >/dev/null 2>&1
[ "$HTTP_CODE" = "200" ] && ok "el producto existe" || falla "el producto $PRODUCTO_ARG no existe (HTTP $HTTP_CODE)"

req GET "$URL_DONADORES/necesidades?productoSolicitadoID=$PRODUCTO_ARG" >/dev/null 2>&1
NECESIDADES=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)
except Exception: print(0)
" 2>/dev/null)
detalle "necesidades insatisfechas del producto: ${NECESIDADES:-0}"
if [ "${NECESIDADES:-0}" = "0" ]; then
  detalle "sin necesidades, las unidades donadas deberian ir al stock"
else
  detalle "con necesidades, el matchmaking deberia asignar y el sobrante ir al stock"
fi

req GET "$URL_LOGISTICA/admin/db/status" >/dev/null 2>&1
ASIG_INICIO=$(campo '.asignaciones'); [ -z "$ASIG_INICIO" ] && ASIG_INICIO=0
req GET "$URL_LOGISTICA/stock/$PRODUCTO_ARG" >/dev/null 2>&1
STOCK_INICIO=$(campo '.cantidadDisponible'); [ -z "$STOCK_INICIO" ] && STOCK_INICIO=0
detalle "al empezar: $ASIG_INICIO asignaciones, $STOCK_INICIO en stock"

# ------------------------------------------------ donar
titulo "REGISTRANDO $VECES DONACION(ES)"

CREADAS=0
RECHAZADAS=0
IDS=""

i=1
while [ "$i" -le "$VECES" ]; do
  if [ "$INCREMENTAL" = "si" ]; then
    ESTA=$((CANTIDAD * i))
  else
    ESTA="$CANTIDAD"
  fi

  paso "Donacion $i de $VECES: $ESTA unidades"
  req POST "$URL_DONACIONES/donaciones" \
    "{\"donadorID\":\"$DONADOR_ARG\",\"depositoID\":\"$DEPOSITO_ARG\",\"descripcion\":\"$PREFIJO donacion manual $i\",\"productoID\":\"$PRODUCTO_ARG\",\"cantidad\":$ESTA}"

  case "$HTTP_CODE" in
    200|201)
      ID=$(campo '.id')
      ok "creada: $ID en estado $(campo '.estado')"
      CREADAS=$((CREADAS + 1))
      IDS="$IDS $ID"
      ULTIMA="$ID"
      ;;
    422)
      RECHAZADAS=$((RECHAZADAS + 1))
      aviso "rechazada (HTTP 422): $(campo '.message')"
      [ "${ESTADO_DONADOR:-}" = "SOSPECHOSO" ] && detalle "esperable: el sorteo del 50% salio negativo"
      ;;
    *)
      RECHAZADAS=$((RECHAZADAS + 1))
      falla "no se pudo registrar (HTTP $HTTP_CODE): $(campo '.message')"
      ;;
  esac

  i=$((i + 1))
done

# ------------------------------------------------ resultado
if [ "$ESPERAR" = "si" ] && [ "$CREADAS" -gt 0 ]; then
  paso "Esperando 25s a que el Worker procese la cola"
  sleep 25
fi

titulo "RESULTADO"
detalle "creadas: $CREADAS   rechazadas: $RECHAZADAS"

req GET "$URL_LOGISTICA/admin/db/status" >/dev/null 2>&1
ASIG_FIN=$(campo '.asignaciones'); [ -z "$ASIG_FIN" ] && ASIG_FIN=0
req GET "$URL_LOGISTICA/stock/$PRODUCTO_ARG" >/dev/null 2>&1
STOCK_FIN=$(campo '.cantidadDisponible'); [ -z "$STOCK_FIN" ] && STOCK_FIN=0

printf "  %-16s %-10s %s\n" "" "ANTES" "DESPUES" >&2
printf "  %-16s %-10s %s\n" "asignaciones" "$ASIG_INICIO" "$ASIG_FIN" >&2
printf "  %-16s %-10s %s\n" "stock" "$STOCK_INICIO" "$STOCK_FIN" >&2
echo "" >&2

if [ "$CREADAS" -eq 0 ]; then
  falla "no se creo ninguna donacion"
elif [ "$ASIG_FIN" -gt "$ASIG_INICIO" ] || [ "$STOCK_FIN" -gt "$STOCK_INICIO" ]; then
  ok "Logistica proceso las donaciones (se movieron asignaciones o stock)"
else
  falla "las donaciones se crearon pero Logistica no las proceso"
  detalle "ni las asignaciones ni el stock se movieron"
  detalle "sintoma tipico de que no hay Worker consumiendo la cola"
  detalle "para el diagnostico completo:  ./10-flujo-registrar-donacion.sh"
fi

if [ -n "${ULTIMA:-}" ]; then
  guardar DONACION "$ULTIMA"
  echo "" >&2
  echo "  Donaciones creadas:$IDS" >&2
  echo "" >&2
  echo "  Que podes hacer ahora:" >&2
  echo "    ./11-flujo-reportar-entrega.sh          reportar la entrega de la ultima" >&2
  echo "    ./14-flujo-queja-baneo.sh              quejarte de la ultima (tiene que estar ACEPTADA)" >&2
  echo "    ./estado.sh                            ver como quedo todo" >&2
fi

resumen
