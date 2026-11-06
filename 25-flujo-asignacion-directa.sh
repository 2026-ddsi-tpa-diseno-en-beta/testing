#!/usr/bin/env bash
# FLUJO LOGISTICA - ASIGNACION DIRECTA DESDE STOCK
#
# Prueba el endpoint directo de Logistica:
#   POST /stock/asignaciones  { necesidadId, productoId, cantidad }
#
# A diferencia del flujo 20, este NO crea la necesidad en Donadores para que Donadores
# dispare la asignacion. Aca se llama directamente a Logistica y se valida:
#   1. existe stock disponible del producto
#   2. /stock/asignaciones devuelve una o mas asignaciones
#   3. la suma asignada coincide con lo pedido, o con todo el stock disponible
#   4. el stock baja exactamente lo asignado
#   5. la asignacion queda ASIGNADA y con origen SOLICITUD_ENTIDAD
#
# Uso:
#   ./25-flujo-asignacion-directa.sh
#   ./25-flujo-asignacion-directa.sh 10 7
#   ./25-flujo-asignacion-directa.sh --stock 10 --cantidad 7 --simular-worker
#
# --simular-worker: sin un Worker consumiendo la cola, la donacion no llega al stock.
#   Con este flag se llama al endpoint interno que el Worker usaria para dejar el paquete
#   como EN_STOCK y poder probar la asignacion directa igual.
set -u
. "$(dirname "$0")/lib/comun.sh"

STOCK_OBJETIVO="10"
CANTIDAD_ASIGNAR="7"
SIMULAR="no"
POSICIONALES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --stock)          STOCK_OBJETIVO="$2"; shift 2 ;;
    --stock=*)        STOCK_OBJETIVO="${1#*=}"; shift ;;
    --cantidad)       CANTIDAD_ASIGNAR="$2"; shift 2 ;;
    --cantidad=*)     CANTIDAD_ASIGNAR="${1#*=}"; shift ;;
    --simular-worker) SIMULAR="si"; shift ;;
    -h|--help|help|ayuda) ayuda --help ;;
    *)
      POSICIONALES=$((POSICIONALES + 1))
      if [ "$POSICIONALES" -eq 1 ]; then
        STOCK_OBJETIVO="$1"
      elif [ "$POSICIONALES" -eq 2 ]; then
        CANTIDAD_ASIGNAR="$1"
      else
        echo "Argumento desconocido: $1  (./25-flujo-asignacion-directa.sh --help)" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

case "$STOCK_OBJETIVO" in
  ''|*[!0-9]*) echo "Stock invalido: '$STOCK_OBJETIVO'. Tiene que ser numerico." >&2; exit 1 ;;
esac
case "$CANTIDAD_ASIGNAR" in
  ''|*[!0-9]*) echo "Cantidad invalida: '$CANTIDAD_ASIGNAR'. Tiene que ser numerica." >&2; exit 1 ;;
esac
[ "$STOCK_OBJETIVO" -gt 0 ] || { echo "El stock tiene que ser mayor a 0." >&2; exit 1; }
[ "$CANTIDAD_ASIGNAR" -gt 0 ] || { echo "La cantidad a asignar tiene que ser mayor a 0." >&2; exit 1; }

exigir_estado DONADOR_OK
exigir_estado DEPOSITO
exigir_estado CATEGORIA

SELLO="$(date +%m%d-%H%M%S)"

contar_lista() {
  printf '%s' "$1" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 0)
except Exception:
    print(0)
" 2>/dev/null
}

sumar_asignado() {
  printf '%s' "$1" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
if not isinstance(d,list):
    d=[d]
print(sum(int(x.get('cantidadAsignada') or 0) for x in d if isinstance(x,dict)))
" 2>/dev/null
}

campo_lista() {
  local campo="$1"
  printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
campo=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    print(''); sys.exit()
if isinstance(d,list) and d:
    print(d[0].get(campo) if d[0].get(campo) is not None else '')
elif isinstance(d,dict):
    print(d.get(campo) if d.get(campo) is not None else '')
" "$campo" 2>/dev/null
}

leer_contador() {
  curl -sS -m "${METRICS_TIMEOUT:-15}" "$1/actuator/metrics/$2" 2>/dev/null \
    | sed -n 's/.*"value":\([0-9][0-9.]*\).*/\1/p' | head -1 | cut -d. -f1
}

delta_contador() {
  local antes="$1" despues="$2"
  case "$antes" in ''|*[!0-9]*) echo ""; return ;; esac
  case "$despues" in ''|*[!0-9]*) echo ""; return ;; esac
  if [ "$despues" -ge "$antes" ] 2>/dev/null; then
    echo $((despues - antes))
  else
    echo "reset"
  fi
}

titulo "FLUJO LOGISTICA - ASIGNACION DIRECTA DESDE STOCK"
echo "Se va a generar stock de $STOCK_OBJETIVO unidades y pedir asignacion directa de $CANTIDAD_ASIGNAR."
[ "$SIMULAR" = "si" ] && echo "${C_WARN}Modo simular-worker activado.${C_OFF}"

# ============================================================ preparar stock
titulo "1. Preparar stock aislado"
detalle "se usa un producto nuevo para que no tenga necesidades ni asignaciones previas"

paso "Producto nuevo"
SUBCAT_FIELD=""
[ -n "${SUBCATEGORIA:-}" ] && SUBCAT_FIELD=",\"subcategoriaID\":\"$SUBCATEGORIA\""
NOMBRE_PRODUCTO=$(json_escape "$PREFIJO Directa $SELLO")
DESC_PRODUCTO=$(json_escape "producto para asignacion directa")
req POST "$URL_DONACIONES/productos" \
  "{\"nombre\":\"$NOMBRE_PRODUCTO\",\"descripcion\":\"$DESC_PRODUCTO\",\"categoriaID\":\"$CATEGORIA\"$SUBCAT_FIELD}"
PRODUCTO_DIRECTO=$(campo '.id')
creado "producto" "$PRODUCTO_DIRECTO" || { resumen; exit 1; }
guardar PRODUCTO_DIRECTO "$PRODUCTO_DIRECTO"

paso "Confirmar que no hay necesidades para este producto"
req GET "$URL_DONADORES/necesidades?productoSolicitadoID=$PRODUCTO_DIRECTO"
NECESIDADES=$(contar_lista "$HTTP_BODY")
verificar "necesidades iniciales" "0" "${NECESIDADES:-0}"

paso "Registrar una donacion para generar stock"
DESC_DONACION=$(json_escape "$PREFIJO donacion para asignacion directa")
req POST "$URL_DONACIONES/donaciones" \
  "{\"donadorID\":\"$DONADOR_OK\",\"depositoID\":\"$DEPOSITO\",\"descripcion\":\"$DESC_DONACION\",\"productoID\":\"$PRODUCTO_DIRECTO\",\"cantidad\":$STOCK_OBJETIVO}"
case "$HTTP_CODE" in
  200|201)
    DONACION_DIRECTA=$(campo '.id')
    ok "donacion creada: $DONACION_DIRECTA"
    guardar DONACION_DIRECTA "$DONACION_DIRECTA"
    ;;
  *)
    falla "no se pudo registrar la donacion (HTTP $HTTP_CODE)"
    resumen; exit 1
    ;;
esac

paso "Esperar 20s a que el Worker mande la donacion a stock"
sleep 20
req GET "$URL_LOGISTICA/stock/$PRODUCTO_DIRECTO"
STOCK_ANTES=$(campo '.cantidadDisponible')
detalle "stock disponible: ${STOCK_ANTES:-0}"

if [ "${STOCK_ANTES:-0}" = "0" ] && [ "$SIMULAR" = "si" ]; then
  paso "Sin stock. Simulando lo que haria el Worker"
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
  PAQUETE_DIRECTO=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('stockActual') or []:
    if p.get('donacionID') == '''${DONACION_DIRECTA}''':
        print(p.get('id')); break
" 2>/dev/null)
  if [ -n "$PAQUETE_DIRECTO" ]; then
    detalle "paquete: $PAQUETE_DIRECTO"
    req POST "$URL_LOGISTICA/internal/matchmaking/resultados" \
      "{\"depositoId\":\"$DEPOSITO\",\"paqueteId\":\"$PAQUETE_DIRECTO\",\"necesidadId\":null,\"cantidadAsignada\":0,\"cantidadSobrante\":$STOCK_OBJETIVO}"
    req GET "$URL_LOGISTICA/stock/$PRODUCTO_DIRECTO"
    STOCK_ANTES=$(campo '.cantidadDisponible')
    detalle "stock ahora: ${STOCK_ANTES:-0}"
  else
    aviso "no se encontro el paquete de la donacion"
  fi
fi

if [ "${STOCK_ANTES:-0}" = "0" ]; then
  falla "no hay stock para probar asignacion directa"
  detalle "opciones: levantar el Worker o correr con --simular-worker"
  resumen; exit 1
fi
ok "hay stock disponible para asignar"

# ============================================================ asignacion directa
titulo "2. Llamar directo a Logistica"

NECESIDAD_DIRECTA="NECESIDAD-DIRECTA-$SELLO"
guardar NECESIDAD_DIRECTA "$NECESIDAD_DIRECTA"

ESPERADO="$CANTIDAD_ASIGNAR"
[ "$ESPERADO" -gt "$STOCK_ANTES" ] 2>/dev/null && ESPERADO="$STOCK_ANTES"

paso "Estado antes"
req GET "$URL_LOGISTICA/admin/db/status"
ASIG_ANTES=$(campo '.asignaciones'); [ -z "$ASIG_ANTES" ] && ASIG_ANTES=0
METRICA_ANTES=$(leer_contador "$URL_LOGISTICA" "logistica.asignaciones.solicitud_entidad")
detalle "asignaciones: $ASIG_ANTES"
detalle "stock: $STOCK_ANTES"
detalle "contador solicitud_entidad: ${METRICA_ANTES:-?}"

paso "POST /stock/asignaciones"
detalle "necesidadId sintetico: $NECESIDAD_DIRECTA"
req POST "$URL_LOGISTICA/stock/asignaciones" \
  "{\"necesidadId\":\"$NECESIDAD_DIRECTA\",\"productoId\":\"$PRODUCTO_DIRECTO\",\"cantidad\":$CANTIDAD_ASIGNAR}"

case "$HTTP_CODE" in
  200)
    CANT_ASIGNACIONES=$(contar_lista "$HTTP_BODY")
    SUMA_ASIGNADA=$(sumar_asignado "$HTTP_BODY")
    ASIGNACION_DIRECTA=$(campo_lista id)
    ok "Logistica devolvio $CANT_ASIGNACIONES asignacion(es)"
    if [ -n "$ASIGNACION_DIRECTA" ]; then
      guardar ASIGNACION_DIRECTA "$ASIGNACION_DIRECTA"
    else
      falla "la respuesta no incluyo id de asignacion"
      resumen; exit 1
    fi
    ;;
  204)
    falla "Logistica respondio 204: no encontro paquetes disponibles, aunque habia stock"
    resumen; exit 1
    ;;
  *)
    falla "fallo la asignacion directa (HTTP $HTTP_CODE)"
    resumen; exit 1
    ;;
esac

verificar "cantidad total asignada" "$ESPERADO" "${SUMA_ASIGNADA:-0}"

paso "Verificar la asignacion creada"
req GET "$URL_LOGISTICA/asignaciones/$ASIGNACION_DIRECTA"
if [ "$HTTP_CODE" = "200" ]; then
  verificar "estado de la asignacion" "ASIGNADA" "$(campo '.estado')"
  verificar "origen de la asignacion" "SOLICITUD_ENTIDAD" "$(campo '.origen')"
  verificar "necesidad asociada" "$NECESIDAD_DIRECTA" "$(campo '.necesidadID')"
  if [ "${CANT_ASIGNACIONES:-0}" = "1" ]; then
    verificar "cantidad asignada" "$ESPERADO" "$(campo '.cantidadAsignada')"
  else
    detalle "la asignacion se repartio en $CANT_ASIGNACIONES paquete(s); se valido la suma total"
  fi
else
  falla "no se pudo leer la asignacion creada (HTTP $HTTP_CODE)"
fi

paso "Verificar que el stock bajo exactamente lo asignado"
req GET "$URL_LOGISTICA/stock/$PRODUCTO_DIRECTO"
STOCK_DESPUES=$(campo '.cantidadDisponible')
STOCK_ESPERADO=$((STOCK_ANTES - ESPERADO))
detalle "stock antes: $STOCK_ANTES  asignado: $ESPERADO  despues: ${STOCK_DESPUES:-?}"
verificar "stock restante" "$STOCK_ESPERADO" "${STOCK_DESPUES:-}"

paso "Verificar que aumento el total de asignaciones"
req GET "$URL_LOGISTICA/admin/db/status"
ASIG_DESPUES=$(campo '.asignaciones'); [ -z "$ASIG_DESPUES" ] && ASIG_DESPUES=0
detalle "asignaciones: $ASIG_ANTES -> $ASIG_DESPUES"
if [ "$ASIG_DESPUES" -gt "$ASIG_ANTES" ]; then
  ok "se crearon asignaciones nuevas"
else
  falla "no aumento el contador de asignaciones"
fi

paso "Metrica de asignaciones por solicitud de entidad"
METRICA_DESPUES=$(leer_contador "$URL_LOGISTICA" "logistica.asignaciones.solicitud_entidad")
DELTA_METRICA=$(delta_contador "${METRICA_ANTES:-}" "${METRICA_DESPUES:-}")
detalle "solicitud_entidad: ${METRICA_ANTES:-?} -> ${METRICA_DESPUES:-?} (delta: ${DELTA_METRICA:-?})"
case "$DELTA_METRICA" in
  reset) aviso "la metrica se reseteo durante la prueba" ;;
  ""|0)  aviso "no se pudo comprobar aumento de metrica; la asignacion ya fue validada por estado y origen" ;;
  *)     ok "la metrica de asignacion directa se movio" ;;
esac

echo ""
echo "Para mostrarlo despues:"
echo "  ./ver-logistica.sh --producto $PRODUCTO_DIRECTO --asignacion $ASIGNACION_DIRECTA --detalle"
echo "  ./ver-estado.sh asignacion $ASIGNACION_DIRECTA"

resumen
