#!/usr/bin/env bash
# FLUJO 1 - REGISTRAR UNA NUEVA DONACION (cadena completa)
#
# Donaciones valida el donador contra Donadores y Entidades, registra la donacion en
# INGRESADA y avisa a Logistica. Logistica valida la cantidad y el lugar en el deposito,
# guarda el paquete y encola el mensaje. Un Worker consume la cola, consulta las
# necesidades insatisfechas, corre el matchmaking y le hace POST de vuelta a Logistica
# para dar de alta la asignacion.
#
# Uso:  ./10-flujo-registrar-donacion.sh [cantidad]
set -u
. "$(dirname "$0")/lib/comun.sh"

CANTIDAD="${1:-40}"
ESPERA="${ESPERA:-25}"

exigir_estado DONADOR_OK
exigir_estado PRODUCTO
exigir_estado DEPOSITO

titulo "FLUJO 1 - REGISTRAR UNA NUEVA DONACION"
echo "donador:  $DONADOR_OK"
echo "producto: $PRODUCTO"
echo "deposito: $DEPOSITO"
echo "cantidad: $CANTIDAD unidades"

# ------------------------------------------------------------------ paso 0
paso "Estado inicial"
req GET "$URL_LOGISTICA/admin/db/status"
ASIG_ANTES=$(campo '.asignaciones')
[ -z "$ASIG_ANTES" ] && ASIG_ANTES=0
detalle "asignaciones en Logistica antes: $ASIG_ANTES"

req GET "$URL_LOGISTICA/stock/$PRODUCTO"
detalle "stock disponible del producto antes: $(campo '.cantidadDisponible')"

# ------------------------------------------------------------------ paso 1
paso "1. Donaciones verifica el donador y registra la donacion"
req GET "$URL_DONADORES/donadores/$DONADOR_OK/puede-donar"
PUEDE=$(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')
if [ "$PUEDE" = "true" ]; then
  ok "el donador puede donar"
else
  aviso "puede-donar devolvio '$PUEDE': si es SOSPECHOSO puede fallar por el 50% aleatorio"
fi

req POST "$URL_DONACIONES/donaciones" \
  "{\"donadorID\":\"$DONADOR_OK\",\"depositoID\":\"$DEPOSITO\",\"descripcion\":\"$PREFIJO donacion de flujo\",\"productoID\":\"$PRODUCTO\",\"cantidad\":$CANTIDAD}"

if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo registrar la donacion (HTTP $HTTP_CODE)"
  resumen; exit 1
fi

DONACION=$(campo '.id')
verificar "la donacion nace en INGRESADA" "INGRESADA" "$(campo '.estado')"
ok "donacion creada: $DONACION"
guardar DONACION "$DONACION"

# ------------------------------------------------------------------ paso 2
paso "2. Logistica guardo el paquete en el deposito"
req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
PAQUETE=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('stockActual') or []:
    if p.get('donacionID') == '''${DONACION}''':
        print(p.get('id')); break
" 2>/dev/null)
if [ -n "$PAQUETE" ] && [ "$PAQUETE" != "null" ]; then
  ok "el paquete de esta donacion esta en el deposito: $PAQUETE"
  guardar PAQUETE "$PAQUETE"
else
  falla "el paquete no aparece en el deposito"
  detalle "Donaciones dijo que registro, pero Logistica no lo tiene"
fi

# ------------------------------------------------------------------ paso 3
paso "3. Esperando ${ESPERA}s a que el Worker consuma la cola"
detalle "el Worker consulta las necesidades, corre el matchmaking y hace POST /internal/matchmaking/resultados"
sleep "$ESPERA"

req GET "$URL_LOGISTICA/admin/db/status"
ASIG_DESPUES=$(campo '.asignaciones')
[ -z "$ASIG_DESPUES" ] && ASIG_DESPUES=0
detalle "asignaciones despues: $ASIG_DESPUES (antes: $ASIG_ANTES)"

if [ "$ASIG_DESPUES" -gt "$ASIG_ANTES" ]; then
  ok "se creo la asignacion: la cola y el worker funcionan"
  if [ -n "${PAQUETE:-}" ]; then
    ASIGNACION=$(python_json - "$URL_LOGISTICA" "$PAQUETE" "$ASIG_DESPUES" <<'PY'
import json, subprocess, sys
base, paquete, limite = sys.argv[1], sys.argv[2], int(sys.argv[3])
for i in range(1, limite + 25):
    try:
        raw = subprocess.check_output(
            ["curl", "-sS", "-m", "20", f"{base}/asignaciones/{i}"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        data = json.loads(raw)
    except Exception:
        continue
    if str(data.get("paqueteID")) == str(paquete):
        print(data.get("id"))
        break
PY
)
    if [ -n "$ASIGNACION" ] && [ "$ASIGNACION" != "null" ]; then
      ok "asignacion asociada al paquete: $ASIGNACION"
      guardar ASIGNACION "$ASIGNACION"
    else
      aviso "no pude identificar el id de asignacion; el flujo 11 puede necesitar argumento"
    fi
  fi
else
  falla "NO se creo ninguna asignacion"

  # Las metricas de la cola dicen exactamente en que eslabon se corto.
  # El export de prometheus quedo deshabilitado al migrar a Grafana: se leen los
  # contadores del endpoint JSON /actuator/metrics. La API publica; el consumo
  # pasa en los workers (instancias aparte en Render).
  paso "Diagnostico automatico: que paso con el mensaje"
  leer_contador() {
    curl -sS -m 60 "$1/actuator/metrics/$2" 2>/dev/null \
      | sed -n 's/.*"value":\([0-9][0-9.]*\).*/\1/p' | head -1 | cut -d. -f1
  }
  PUB=$(leer_contador "$URL_LOGISTICA" "rabbitmq.published")
  CONS=0; REJ=0; VIVOS=0
  for wurl in "${URL_LOGISTICA_WORKER_1:-}" "${URL_LOGISTICA_WORKER_2:-}"; do
    [ -n "$wurl" ] || continue
    c=$(leer_contador "$wurl" "rabbitmq.consumed")
    r=$(leer_contador "$wurl" "rabbitmq.rejected")
    if [ -n "$c" ]; then CONS=$((CONS + c)); VIVOS=$((VIVOS + 1)); fi
    [ -n "$r" ] && REJ=$((REJ + r))
  done

  detalle "publicados (API): ${PUB:-?}   consumidos (workers): $CONS   rechazados: $REJ"
  detalle "workers respondiendo metricas: $VIVOS"
  echo ""

  if [ "${PUB:-0}" = "0" ]; then
    echo "    ${C_WARN}El mensaje NO se publico a la cola.${C_OFF}"
    echo "    Revisar la conexion a RabbitMQ: la variable RABBITMQ_URL en Render"
    echo "    y el estado del broker en $URL_LOGISTICA/actuator/health"
  elif [ "$VIVOS" = "0" ]; then
    echo "    ${C_WARN}Ningun worker respondio metricas.${C_OFF}"
    echo "    O estan caidos/dormidos en Render, o faltan URL_LOGISTICA_WORKER_1/2"
    echo "    en tu config.sh (ver config.sh.example). Correr 00-salud.sh primero."
  elif [ "${CONS:-0}" = "0" ]; then
    echo "    ${C_WARN}Se publico pero los workers no lo consumieron.${C_OFF}"
    echo ""
    echo "    Revisar en Render que los servicios worker esten suscriptos a la cola"
    echo "    (RABBITMQ_URL correcta y misma queue que la API)."
    echo ""
    echo "    Alternativa: levantar un worker local (el enunciado lo permite durante la entrega):"
    echo "      cd Componente_Logistica"
    echo "      SPRING_PROFILES_ACTIVE=worker \\"
    echo "      RABBITMQ_URL=<la de CloudAMQP> \\"
    echo "      DONADORES_URL=$URL_DONADORES \\"
    echo "      LOGISTICA_API_URL=$URL_LOGISTICA \\"
    echo "      java -jar target/*-worker.jar"
  elif [ "${REJ:-0}" != "0" ]; then
    echo "    ${C_WARN}Se consumio pero el worker lo RECHAZO (fue al DLQ).${C_OFF}"
    echo "    El worker fallo procesandolo. Las causas mas probables:"
    echo "    - LOGISTICA_API_URL mal seteada: si cae en el default http://localhost:8080"
    echo "      el POST de vuelta va a un puerto vacio, porque Render asigna el puerto"
    echo "      por la variable PORT (suele ser 10000)."
    echo "    - DONADORES_URL mal seteada en el worker."
    echo "    Mirar los logs del servicio worker en Render para ver la excepcion."
  else
    echo "    ${C_WARN}Se consumio y no se rechazo, pero no hay asignacion.${C_OFF}"
    echo "    Puede que el matchmaking no haya encontrado ninguna necesidad elegible."
    echo "    Verificar que exista una insatisfecha para este producto:"
    echo "      curl -s '$URL_DONADORES/necesidades?productoSolicitadoID=$PRODUCTO'"
  fi
fi

# ------------------------------------------------------------------ paso 4
paso "4. Como quedo el stock"
req GET "$URL_LOGISTICA/stock/$PRODUCTO"
STOCK=$(campo '.cantidadDisponible')
detalle "stock disponible: $STOCK"
detalle "la parte asignada no cuenta como stock; el sobrante si"

paso "5. Estado final de la donacion"
req GET "$URL_DONACIONES/donaciones/$DONACION"
verificar "sigue en INGRESADA hasta que se reporte la entrega" "INGRESADA" "$(campo '.estado')"

echo ""
echo "Siguiente paso del guion:  ./11-flujo-reportar-entrega.sh"

resumen
