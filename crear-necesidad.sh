#!/usr/bin/env bash
# Crea UNA necesidad material.
#
# Al crearla, Donadores y Entidades tiene que (Entrega 4):
#   1. corroborar con Donaciones que el producto sea valido
#   2. consultar a Logistica si hay stock del producto
#   3. si hay, asignar en el momento lo disponible o lo necesario
# El script mide el stock antes y despues para mostrar si eso ocurrio.
#
# Tipos:
#   EXTRAORDINARIA -> admite satisfaccion parcial, en varias instancias
#   RECURRENTE     -> no admite parcial: se cubre en una unica entrega por periodo
#
# Uso:
#   ./crear-necesidad.sh
#   ./crear-necesidad.sh --producto 9 --cantidad 100
#   ./crear-necesidad.sh --entidad abc --producto 9 --cantidad 50 --tipo RECURRENTE --urgencia 10
#   ./crear-necesidad.sh --producto 9 --cantidad 9 --guardar-como NEC_DEMO
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

ENTIDAD_ARG=""; PRODUCTO_ARG=""; CANTIDAD=""; TIPO=""; URGENCIA=""
DESCRIPCION=""; GUARDAR_COMO="NECESIDAD"

while [ $# -gt 0 ]; do
  case "$1" in
    --entidad)       ENTIDAD_ARG="$2"; shift 2 ;;
    --producto)      PRODUCTO_ARG="$2"; shift 2 ;;
    --cantidad)      CANTIDAD="$2"; shift 2 ;;
    --tipo)          TIPO="$2"; shift 2 ;;
    --urgencia)      URGENCIA="$2"; shift 2 ;;
    --descripcion)   DESCRIPCION="$2"; shift 2 ;;
    --guardar-como)  GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-necesidad.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UNA NECESIDAD MATERIAL"

# Muestra entidades y productos cuando es interactivo, para no tener que buscar IDs a mano.
if [ -t 0 ] && { [ -z "$ENTIDAD_ARG" ] || [ -z "$PRODUCTO_ARG" ]; }; then
  if [ -z "$ENTIDAD_ARG" ]; then
    req GET "$URL_DONADORES/entidades" >/dev/null 2>&1
    detalle "entidades que existen:"
    printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d[-6:]: print('    ' + str(x.get('id')) + '  ' + str(x.get('razonSocial')))
" >&2 2>/dev/null
  fi
  if [ -z "$PRODUCTO_ARG" ]; then
    req GET "$URL_DONACIONES/productos" >/dev/null 2>&1
    detalle "productos que existen:"
    printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d[-6:]: print('    ' + str(x.get('id')) + '  ' + str(x.get('nombre')))
" >&2 2>/dev/null
  fi
fi

preguntar ENTIDAD_ARG  "ID de la entidad"                    "${ENTIDAD:-}"
preguntar PRODUCTO_ARG "ID del producto solicitado"          "${PRODUCTO:-}"
preguntar CANTIDAD     "Cantidad objetivo"                   "100"
preguntar TIPO         "Tipo (EXTRAORDINARIA / RECURRENTE)"  "EXTRAORDINARIA"
preguntar URGENCIA     "Nivel de urgencia (1 a 10)"          "5"
preguntar DESCRIPCION  "Descripcion"                         "$PREFIJO necesidad de $CANTIDAD unidades"

# ------------------------------------------------ stock antes
paso "Stock disponible del producto ANTES"
req GET "$URL_LOGISTICA/stock/$PRODUCTO_ARG"
STOCK_ANTES=$(campo '.cantidadDisponible'); [ -z "$STOCK_ANTES" ] && STOCK_ANTES=0
detalle "stock: $STOCK_ANTES unidades"
if [ "${STOCK_ANTES:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$STOCK_ANTES" -ge "$CANTIDAD" ]; then
    detalle "alcanza para cubrir la necesidad entera: se espera asignacion inmediata de $CANTIDAD"
  else
    detalle "no alcanza para cubrirla entera ($STOCK_ANTES de $CANTIDAD)"
    [ "$TIPO" = "EXTRAORDINARIA" ] \
      && detalle "es EXTRAORDINARIA: deberia aceptar la asignacion parcial de $STOCK_ANTES" \
      || detalle "es RECURRENTE: NO deberia aceptar asignacion parcial"
  fi
else
  detalle "sin stock: no puede haber asignacion inmediata"
fi

req GET "$URL_LOGISTICA/admin/db/status" >/dev/null 2>&1
ASIG_ANTES=$(campo '.asignaciones'); [ -z "$ASIG_ANTES" ] && ASIG_ANTES=0

# ------------------------------------------------ alta
paso "POST /necesidades"
req POST "$URL_DONADORES/necesidades" \
  "{\"entidadID\":\"$ENTIDAD_ARG\",\"productoSolicitadoID\":\"$PRODUCTO_ARG\",\"descripcion\":\"$DESCRIPCION\",\"cantidadObjetivo\":$CANTIDAD,\"nivelDeUrgencia\":$URGENCIA,\"tipo\":\"$TIPO\"}"

NECESIDAD_NUEVA=$(campo '.id')
if ! creado "necesidad" "$NECESIDAD_NUEVA"; then
  echo "" >&2
  echo "    ${C_WARN}Si rechazo el producto:${C_OFF} el enunciado pide validarlo contra Donaciones." >&2
  echo "    Verifica que el producto $PRODUCTO_ARG exista:" >&2
  echo "      curl -s $URL_DONACIONES/productos/$PRODUCTO_ARG" >&2
  resumen; exit 1
fi

# ------------------------------------------------ stock despues
paso "Stock DESPUES (para ver si hubo asignacion inmediata)"
sleep 3
req GET "$URL_LOGISTICA/stock/$PRODUCTO_ARG"
STOCK_DESPUES=$(campo '.cantidadDisponible'); [ -z "$STOCK_DESPUES" ] && STOCK_DESPUES=0
ASIGNADO=$((STOCK_ANTES - STOCK_DESPUES))
detalle "stock: $STOCK_ANTES -> $STOCK_DESPUES   (asignadas desde stock: $ASIGNADO)"

req GET "$URL_LOGISTICA/admin/db/status" >/dev/null 2>&1
ASIG_DESPUES=$(campo '.asignaciones'); [ -z "$ASIG_DESPUES" ] && ASIG_DESPUES=0
detalle "asignaciones en Logistica: $ASIG_ANTES -> $ASIG_DESPUES"

if [ "$ASIGNADO" -gt 0 ]; then
  ok "hubo asignacion inmediata de $ASIGNADO unidades desde stock"
  if [ "$TIPO" = "RECURRENTE" ] && [ "$ASIGNADO" -lt "$CANTIDAD" ]; then
    falla "es RECURRENTE y recibio una asignacion PARCIAL de $ASIGNADO de $CANTIDAD"
    detalle "el enunciado dice que una recurrente se cubre en una unica entrega"
  fi
elif [ "${STOCK_ANTES:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$TIPO" = "RECURRENTE" ] && [ "$STOCK_ANTES" -lt "$CANTIDAD" ]; then
    ok "no se asigno nada, que es lo correcto para una RECURRENTE con stock insuficiente"
  else
    falla "habia $STOCK_ANTES en stock y no se asigno nada"
    detalle "revisar que Donadores consulte el stock a Logistica al crear la necesidad"
  fi
else
  detalle "sin stock previo, no habia nada que asignar"
fi

guardar "$GUARDAR_COMO" "$NECESIDAD_NUEVA"

echo "" >&2
echo "  Para ver las insatisfechas de este producto:" >&2
echo "    curl -s '$URL_DONADORES/necesidades?productoSolicitadoID=$PRODUCTO_ARG'" >&2

echo "$NECESIDAD_NUEVA"
resumen
