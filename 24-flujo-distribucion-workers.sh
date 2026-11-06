#!/usr/bin/env bash
# FLUJO LOGISTICA - DISTRIBUCION DE CARGA ENTRE WORKERS
#
# Demuestra que hay mas de un worker consumiendo mensajes de la cola:
#   1. verifica que Worker-1 y Worker-2 respondan metricas
#   2. toma los contadores rabbitmq.consumed/rejected antes
#   3. registra varias donaciones para publicar mensajes
#   4. espera a que los workers consuman
#   5. compara cuanto consumio cada worker
#
# Uso:
#   ./24-flujo-distribucion-workers.sh
#   ./24-flujo-distribucion-workers.sh 12
#
# Requisito: URL_LOGISTICA_WORKER_1 y URL_LOGISTICA_WORKER_2 tienen que estar configuradas
# en config.sh o venir del config.sh.example.
set -u
. "$(dirname "$0")/lib/comun.sh"

CANTIDAD="${1:-8}"
ESPERA="${ESPERA:-45}"

exigir_estado DONADOR_OK
exigir_estado DEPOSITO
exigir_estado CATEGORIA

case "$CANTIDAD" in
  ''|*[!0-9]*) echo "Cantidad invalida: '$CANTIDAD'. Tiene que ser numerica." >&2; exit 1 ;;
esac

leer_contador() {
  curl -sS -m "${METRICS_TIMEOUT:-20}" "$1/actuator/metrics/$2" 2>/dev/null \
    | sed -n 's/.*"value":\([0-9][0-9.]*\).*/\1/p' | head -1 | cut -d. -f1
}

leer_salud() {
  curl -sS -m "${METRICS_TIMEOUT:-20}" -o /dev/null -w '%{http_code}' "$1/actuator/health" 2>/dev/null
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

mostrar_worker() {
  local nombre="$1" url="$2" cons="$3" rej="$4" salud="$5"
  printf "  %-9s health=%-4s consumed=%-6s rejected=%s\n" \
    "$nombre" "${salud:-000}" "${cons:-?}" "${rej:-?}" >&2
}

SELLO="$(date +%m%d-%H%M%S)"

titulo "FLUJO LOGISTICA - DISTRIBUCION ENTRE WORKERS"
echo "Se van a registrar $CANTIDAD donaciones para generar mensajes en la cola."
echo "Despues se compara cuanto consumio cada worker."

if [ -z "${URL_LOGISTICA_WORKER_1:-}" ] || [ -z "${URL_LOGISTICA_WORKER_2:-}" ]; then
  falla "faltan URL_LOGISTICA_WORKER_1 o URL_LOGISTICA_WORKER_2"
  detalle "revisar testing/config.sh o testing/config.sh.example"
  resumen; exit 1
fi

# ============================================================ workers antes
titulo "1. Workers antes de publicar"

W1_HEALTH=$(leer_salud "$URL_LOGISTICA_WORKER_1")
W2_HEALTH=$(leer_salud "$URL_LOGISTICA_WORKER_2")
W1_CONS_ANTES=$(leer_contador "$URL_LOGISTICA_WORKER_1" "rabbitmq.consumed")
W2_CONS_ANTES=$(leer_contador "$URL_LOGISTICA_WORKER_2" "rabbitmq.consumed")
W1_REJ_ANTES=$(leer_contador "$URL_LOGISTICA_WORKER_1" "rabbitmq.rejected")
W2_REJ_ANTES=$(leer_contador "$URL_LOGISTICA_WORKER_2" "rabbitmq.rejected")
PUB_ANTES=$(leer_contador "$URL_LOGISTICA" "rabbitmq.published")

mostrar_worker "Worker-1" "$URL_LOGISTICA_WORKER_1" "$W1_CONS_ANTES" "$W1_REJ_ANTES" "$W1_HEALTH"
mostrar_worker "Worker-2" "$URL_LOGISTICA_WORKER_2" "$W2_CONS_ANTES" "$W2_REJ_ANTES" "$W2_HEALTH"
printf "  API       published=%s\n" "${PUB_ANTES:-?}" >&2

if [ "$W1_HEALTH" != "200" ] || [ "$W2_HEALTH" != "200" ]; then
  falla "no estan los dos workers UP"
  detalle "para demostrar distribucion tienen que responder ambos"
  resumen; exit 1
fi

if [ -z "${W1_CONS_ANTES:-}" ] || [ -z "${W2_CONS_ANTES:-}" ]; then
  falla "no se pudieron leer metricas rabbitmq.consumed en ambos workers"
  detalle "sin metricas por worker no se puede demostrar distribucion"
  resumen; exit 1
fi

ok "los dos workers responden health y metricas"

# ============================================================ preparar producto
titulo "2. Preparar producto sin necesidades"
detalle "asi los mensajes solo prueban consumo de cola; si no hay necesidades, el worker manda al stock"

SUBCAT_FIELD=""
[ -n "${SUBCATEGORIA:-}" ] && SUBCAT_FIELD=",\"subcategoriaID\":\"$SUBCATEGORIA\""

paso "Crear producto para la prueba"
req POST "$URL_DONACIONES/productos" \
  "{\"nombre\":\"$PREFIJO Workers $SELLO\",\"descripcion\":\"producto para distribuir carga\",\"categoriaID\":\"$CATEGORIA\"$SUBCAT_FIELD}"
PRODUCTO_WORKERS=$(campo '.id')
creado "producto" "$PRODUCTO_WORKERS" || { resumen; exit 1; }
guardar PRODUCTO_WORKERS "$PRODUCTO_WORKERS"

paso "Confirmar que no tiene necesidades"
req GET "$URL_DONADORES/necesidades?productoSolicitadoID=$PRODUCTO_WORKERS"
NECESIDADES=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 0)
except Exception:
    print(0)
" 2>/dev/null)
verificar "necesidades para el producto nuevo" "0" "${NECESIDADES:-0}"

# ============================================================ publicar
titulo "3. Publicar $CANTIDAD mensaje(s)"

CREADAS=0
i=1
while [ "$i" -le "$CANTIDAD" ]; do
  paso "Donacion $i/$CANTIDAD"
  req POST "$URL_DONACIONES/donaciones" \
    "{\"donadorID\":\"$DONADOR_OK\",\"depositoID\":\"$DEPOSITO\",\"descripcion\":\"$PREFIJO distribucion worker $i\",\"productoID\":\"$PRODUCTO_WORKERS\",\"cantidad\":1}"
  case "$HTTP_CODE" in
    200|201)
      CREADAS=$((CREADAS + 1))
      DONACION_WORKERS=$(campo '.id')
      guardar DONACION_WORKERS "$DONACION_WORKERS"
      ok "donacion creada: $DONACION_WORKERS"
      ;;
    *)
      falla "no se pudo crear la donacion $i (HTTP $HTTP_CODE)"
      ;;
  esac
  i=$((i + 1))
done

if [ "$CREADAS" -eq 0 ]; then
  falla "no se creo ninguna donacion; no hay mensajes para distribuir"
  resumen; exit 1
fi

paso "Esperar ${ESPERA}s a que los workers consuman"
sleep "$ESPERA"

# ============================================================ despues
titulo "4. Workers despues de consumir"

W1_CONS_DESPUES=$(leer_contador "$URL_LOGISTICA_WORKER_1" "rabbitmq.consumed")
W2_CONS_DESPUES=$(leer_contador "$URL_LOGISTICA_WORKER_2" "rabbitmq.consumed")
W1_REJ_DESPUES=$(leer_contador "$URL_LOGISTICA_WORKER_1" "rabbitmq.rejected")
W2_REJ_DESPUES=$(leer_contador "$URL_LOGISTICA_WORKER_2" "rabbitmq.rejected")
PUB_DESPUES=$(leer_contador "$URL_LOGISTICA" "rabbitmq.published")

W1_DELTA=$(delta_contador "${W1_CONS_ANTES:-}" "${W1_CONS_DESPUES:-}")
W2_DELTA=$(delta_contador "${W2_CONS_ANTES:-}" "${W2_CONS_DESPUES:-}")
W1_REJ_DELTA=$(delta_contador "${W1_REJ_ANTES:-0}" "${W1_REJ_DESPUES:-0}")
W2_REJ_DELTA=$(delta_contador "${W2_REJ_ANTES:-0}" "${W2_REJ_DESPUES:-0}")
PUB_DELTA=$(delta_contador "${PUB_ANTES:-}" "${PUB_DESPUES:-}")

printf "  %-9s antes=%-6s despues=%-6s delta=%s\n" \
  "Worker-1" "${W1_CONS_ANTES:-?}" "${W1_CONS_DESPUES:-?}" "${W1_DELTA:-?}" >&2
printf "  %-9s antes=%-6s despues=%-6s delta=%s\n" \
  "Worker-2" "${W2_CONS_ANTES:-?}" "${W2_CONS_DESPUES:-?}" "${W2_DELTA:-?}" >&2
printf "  %-9s antes=%-6s despues=%-6s delta=%s\n" \
  "API" "${PUB_ANTES:-?}" "${PUB_DESPUES:-?}" "${PUB_DELTA:-?}" >&2
printf "  rechazados nuevos: Worker-1=%s Worker-2=%s\n" \
  "${W1_REJ_DELTA:-?}" "${W2_REJ_DELTA:-?}" >&2

case "$PUB_DELTA" in
  reset) aviso "el contador published de la API se reseteo durante la prueba" ;;
  ""|0)  aviso "no se pudo comprobar incremento de publicados en API" ;;
  *)     [ "$PUB_DELTA" -ge "$CREADAS" ] 2>/dev/null \
           && ok "la API publico al menos $CREADAS mensaje(s)" \
           || aviso "published subio $PUB_DELTA, pero se crearon $CREADAS donaciones" ;;
esac

if [ "$W1_DELTA" = "reset" ] || [ "$W2_DELTA" = "reset" ]; then
  aviso "un contador de worker se reseteo: Render puede haber reiniciado una instancia"
  detalle "volver a correr el script con los workers ya despiertos"
elif [ "${W1_DELTA:-0}" -gt 0 ] 2>/dev/null && [ "${W2_DELTA:-0}" -gt 0 ] 2>/dev/null; then
  ok "la carga se distribuyo: consumieron Worker-1 y Worker-2"
elif [ "${W1_DELTA:-0}" -gt 0 ] 2>/dev/null || [ "${W2_DELTA:-0}" -gt 0 ] 2>/dev/null; then
  falla "solo un worker consumio mensajes nuevos"
  detalle "revisar que ambos workers apunten al mismo RABBITMQ_URL y a la misma cola"
  detalle "tambien puede pasar si uno se desperto tarde; correr 00-salud.sh y repetir"
else
  falla "ningun worker consumio mensajes nuevos"
  detalle "revisar RABBITMQ_URL, health de workers y logs en Render"
fi

if [ "${W1_REJ_DELTA:-0}" != "0" ] || [ "${W2_REJ_DELTA:-0}" != "0" ]; then
  aviso "hubo mensajes rechazados durante la prueba"
  detalle "si aumentan los rejected, mirar logs de los workers"
fi

paso "Stock generado por el producto de prueba"
req GET "$URL_LOGISTICA/stock/$PRODUCTO_WORKERS"
detalle "cantidadDisponible: $(campo '.cantidadDisponible')"

echo ""
echo "Para repetir con mas carga:"
echo "  ./24-flujo-distribucion-workers.sh 12"

resumen
