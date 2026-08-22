#!/usr/bin/env bash
# FLUJO E4 - CREAR UNA NECESIDAD: VALIDAR PRODUCTO, CONSULTAR STOCK Y ASIGNAR AL MOMENTO
#
# Es el requisito nuevo de la Entrega 4 para Donadores y Entidades. Al crear una necesidad:
#   1. corroborar con Donaciones que el producto solicitado sea valido
#   2. consultar a Logistica si hay stock disponible de ese producto
#   3. si hay, asignar en el momento la cantidad disponible (si la necesidad supera al
#      stock) o la necesaria (si el stock supera a la necesidad)
#   4. la asignacion tiene que poder distinguirse de una hecha por matchmaking
#
# El caso que se prueba: hay stock de N unidades y se crea una necesidad de N-1 del mismo
# producto, asi que tiene que asignarse directo y quedar 1 unidad en stock.
#
# Uso:  ./20-flujo-necesidad-y-stock.sh [cantidad]
#       ./20-flujo-necesidad-y-stock.sh 10 --simular-worker
#
# --simular-worker: sin un Worker consumiendo la cola, una donacion nunca llega al stock.
#   Con este flag se llama al endpoint interno que el Worker usaria, para poder probar el
#   resto de la cadena igual.
set -u
. "$(dirname "$0")/lib/comun.sh"

CANTIDAD="${1:-10}"
SIMULAR="no"
for arg in "$@"; do
  [ "$arg" = "--simular-worker" ] && SIMULAR="si"
done

exigir_estado DONADOR_OK
exigir_estado ENTIDAD
exigir_estado DEPOSITO
exigir_estado CATEGORIA

SELLO="$(date +%H%M%S)"

titulo "FLUJO E4 - NECESIDAD CONTRA STOCK"
echo "Se va a generar stock de $CANTIDAD unidades de un producto nuevo,"
echo "y despues crear una necesidad de $((CANTIDAD - 1)) del mismo producto."
[ "$SIMULAR" = "si" ] && echo "${C_WARN}Modo simular-worker activado.${C_OFF}"

# ============================================================ 1. validacion
titulo "1. Donadores tiene que validar el producto contra Donaciones"

paso "Intentar crear una necesidad con un producto que no existe"
detalle "si la validacion funciona, tiene que rechazarla"
req POST "$URL_DONADORES/necesidades" \
  "{\"entidadID\":\"$ENTIDAD\",\"productoSolicitadoID\":\"PRODUCTO-INEXISTENTE-$SELLO\",\"descripcion\":\"$PREFIJO validacion\",\"cantidadObjetivo\":5,\"nivelDeUrgencia\":5,\"tipo\":\"EXTRAORDINARIA\"}"

case "$HTTP_CODE" in
  400|404|422|502)
    ok "rechazada con HTTP $HTTP_CODE: Donadores valida el producto contra Donaciones" ;;
  200|201)
    falla "la acepto (HTTP $HTTP_CODE) con un producto que no existe"
    detalle "el enunciado pide corroborar el producto con Donaciones antes de crear la necesidad"
    detalle "revisar que URL_DONACIONES este configurada en Donadores y Entidades" ;;
  *)
    aviso "respondio HTTP $HTTP_CODE, no es concluyente" ;;
esac

# ============================================================ 2. generar stock
titulo "2. Generar stock de un producto sin necesidades"
detalle "si no hay necesidades para el producto, las unidades donadas van al stock"

paso "Producto nuevo (para arrancar sin necesidades asociadas)"
SUBCAT_FIELD=""
[ -n "${SUBCATEGORIA:-}" ] && SUBCAT_FIELD=",\"subcategoriaID\":\"$SUBCATEGORIA\""
req POST "$URL_DONACIONES/productos" \
  "{\"nombre\":\"$PREFIJO Stock $SELLO\",\"descripcion\":\"producto para probar stock\",\"categoriaID\":\"$CATEGORIA\"$SUBCAT_FIELD}"
PROD_STOCK=$(campo '.id')
if [ -z "$PROD_STOCK" ] || [ "$PROD_STOCK" = "null" ]; then
  falla "no se pudo crear el producto"; resumen; exit 1
fi
ok "producto: $PROD_STOCK"

paso "Confirmar que no tiene necesidades"
req GET "$URL_DONADORES/necesidades?productoSolicitadoID=$PROD_STOCK"
CANT_NEC=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)
except Exception: print(0)
" 2>/dev/null)
verificar "necesidades para el producto nuevo" "0" "${CANT_NEC:-0}"

paso "Registrar una donacion de $CANTIDAD unidades"
req POST "$URL_DONACIONES/donaciones" \
  "{\"donadorID\":\"$DONADOR_OK\",\"depositoID\":\"$DEPOSITO\",\"descripcion\":\"$PREFIJO donacion para stock\",\"productoID\":\"$PROD_STOCK\",\"cantidad\":$CANTIDAD}"
if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo registrar la donacion (HTTP $HTTP_CODE)"; resumen; exit 1
fi
DONACION_STOCK=$(campo '.id')
ok "donacion: $DONACION_STOCK"

paso "Esperando 20s a que el Worker la mande al stock"
sleep 20
req GET "$URL_LOGISTICA/stock/$PROD_STOCK"
STOCK=$(campo '.cantidadDisponible')
detalle "stock disponible: ${STOCK:-0}"

if [ "${STOCK:-0}" = "0" ] && [ "$SIMULAR" = "si" ]; then
  paso "Sin stock. Simulando lo que haria el Worker"
  detalle "busco el paquete pendiente y lo marco EN_STOCK via el endpoint interno"
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
  PAQUETE=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('stockActual') or []:
    if p.get('donacionID') == '''${DONACION_STOCK}''':
        print(p.get('id')); break
" 2>/dev/null)
  if [ -n "$PAQUETE" ]; then
    detalle "paquete: $PAQUETE"
    req POST "$URL_LOGISTICA/internal/matchmaking/resultados" \
      "{\"depositoId\":\"$DEPOSITO\",\"paqueteId\":\"$PAQUETE\",\"necesidadId\":null,\"cantidadAsignada\":0,\"cantidadSobrante\":$CANTIDAD}"
    req GET "$URL_LOGISTICA/stock/$PROD_STOCK"
    STOCK=$(campo '.cantidadDisponible')
    detalle "stock ahora: ${STOCK:-0}"
  else
    aviso "no se encontro el paquete de la donacion"
  fi
fi

if [ "${STOCK:-0}" = "0" ]; then
  falla "no hay stock del producto: no se puede probar la asignacion inmediata"
  echo ""
  echo "    ${C_WARN}Sin un Worker consumiendo la cola, una donacion nunca llega al stock.${C_OFF}"
  echo "    Opciones:"
  echo "    - levantar un Worker (ver README) y volver a correr este script"
  echo "    - correrlo con:  ./20-flujo-necesidad-y-stock.sh $CANTIDAD --simular-worker"
  resumen; exit 1
fi
ok "hay $STOCK unidades en stock"

# ============================================================ 3. asignacion
titulo "3. Crear una necesidad de $((STOCK - 1)) y esperar asignacion inmediata"

OBJETIVO=$((STOCK - 1))
[ "$OBJETIVO" -lt 1 ] && OBJETIVO=1

paso "Asignaciones antes"
req GET "$URL_LOGISTICA/admin/db/status"
ASIG_ANTES=$(campo '.asignaciones'); [ -z "$ASIG_ANTES" ] && ASIG_ANTES=0
detalle "asignaciones: $ASIG_ANTES"

paso "POST /necesidades con cantidadObjetivo=$OBJETIVO (una menos que el stock)"
detalle "el stock alcanza para cubrirla entera, asi que se tiene que asignar al momento"
req POST "$URL_DONADORES/necesidades" \
  "{\"entidadID\":\"$ENTIDAD\",\"productoSolicitadoID\":\"$PROD_STOCK\",\"descripcion\":\"$PREFIJO necesidad contra stock\",\"cantidadObjetivo\":$OBJETIVO,\"nivelDeUrgencia\":8,\"tipo\":\"EXTRAORDINARIA\"}"
if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo crear la necesidad (HTTP $HTTP_CODE)"; resumen; exit 1
fi
NECESIDAD_STOCK=$(campo '.id')
ok "necesidad: $NECESIDAD_STOCK"

paso "El stock tiene que haber bajado de $STOCK a 1"
sleep 3
req GET "$URL_LOGISTICA/stock/$PROD_STOCK"
STOCK_DESPUES=$(campo '.cantidadDisponible')
detalle "stock: ${STOCK_DESPUES:-?} (antes: $STOCK, se pidieron $OBJETIVO)"
verificar "stock restante" "1" "${STOCK_DESPUES:-}"

paso "Se tiene que haber creado la asignacion"
req GET "$URL_LOGISTICA/admin/db/status"
ASIG_DESPUES=$(campo '.asignaciones'); [ -z "$ASIG_DESPUES" ] && ASIG_DESPUES=0
detalle "asignaciones: $ASIG_DESPUES (antes: $ASIG_ANTES)"
if [ "$ASIG_DESPUES" -gt "$ASIG_ANTES" ]; then
  ok "se creo la asignacion desde stock, sin pasar por la cola"
else
  falla "no se creo ninguna asignacion"
  echo ""
  echo "    ${C_WARN}Que revisar en Donadores y Entidades:${C_OFF}"
  echo "    - Que URL_LOGISTICA este configurada."
  echo "    - Que registrarNecesidad consulte el stock y pida la asignacion."
  echo "      Logistica lo expone en:"
  echo "         GET  /stock/{productoId}"
  echo "         POST /stock/asignaciones  {necesidadId, productoId, cantidad}"
fi

paso "La asignacion tiene que distinguirse de una de matchmaking"
detalle "el enunciado lo pide para alimentar las misiones nuevas de Incentivos"
METRICAS=$(curl -sS -m "$TIMEOUT" "$URL_LOGISTICA/actuator/prometheus" 2>/dev/null)
POR_ENTIDAD=$(printf '%s' "$METRICAS" | grep "^logistica_asignaciones_solicitud_entidad_total" | head -1 | awk '{print $2}')
POR_MM=$(printf '%s' "$METRICAS" | grep "^logistica_asignaciones_matchmaking_total" | head -1 | awk '{print $2}')
detalle "por solicitud de entidad: ${POR_ENTIDAD:-?}   por matchmaking: ${POR_MM:-?}"
case "${POR_ENTIDAD:-0}" in
  0|0.0|"") aviso "el contador de asignaciones por solicitud esta en 0"
            detalle "puede ser el balanceador de Render: el contador que se lee no es"
            detalle "necesariamente el de la instancia que atendio el pedido" ;;
  *)        ok "el contador de asignaciones por solicitud de entidad se movio" ;;
esac

guardar PROD_STOCK "$PROD_STOCK"
guardar NECESIDAD_STOCK "$NECESIDAD_STOCK"

echo ""
echo "Siguiente:  ./21-flujo-parcialidad-por-tipo.sh"

resumen
