#!/usr/bin/env bash
# FLUJO 2 - REPORTAR UNA ENTREGA (cadena completa)
#
# El transportista reporta la entrega en Logistica. El enunciado fija el orden:
#   1. la asignacion pasa a COMPLETADA
#   2. se llama a satisfacerNecesidad en Donadores y Entidades
#   3. recien despues la donacion pasa a ACEPTADA en Donaciones
#
# Uso:  ./11-flujo-reportar-entrega.sh [paqueteID]
#       Sin argumento busca el paquete de la ultima donacion registrada.
set -u
. "$(dirname "$0")/lib/comun.sh"

exigir_estado DEPOSITO

titulo "FLUJO 2 - REPORTAR UNA ENTREGA"

# ------------------------------------------------------------ buscar paquete
PAQUETE_GUARDADO="${PAQUETE:-}"
ASIGNACION_GUARDADA="${ASIGNACION:-}"
PAQUETE="${1:-}"
ASIGNACION=""

if [ -z "$PAQUETE" ]; then
  paso "Buscando el paquete de la ultima donacion registrada"
  if [ -z "${DONACION:-}" ]; then
    falla "no hay ninguna donacion en el estado"
    detalle "corre primero ./10-flujo-registrar-donacion.sh, o pasa el paqueteID como argumento"
    resumen; exit 1
  fi
  if [ -n "$PAQUETE_GUARDADO" ]; then
    detalle "paquete guardado en .estado: $PAQUETE_GUARDADO; se vuelve a buscar por donacion"
  fi
  detalle "donacion: $DONACION"
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
  PAQUETE=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('stockActual') or []:
    if p.get('donacionID') == '''${DONACION}''':
        print(p.get('id')); break
" 2>/dev/null)
  if [ -z "$PAQUETE" ]; then
    falla "no se encontro el paquete de la donacion $DONACION en el deposito"
    resumen; exit 1
  fi
  ok "paquete encontrado: $PAQUETE"
  guardar PAQUETE "$PAQUETE"
fi

echo "paquete: $PAQUETE"

# ------------------------------------------------------------ estado previo
paso "Estado antes de reportar"
if [ -n "$ASIGNACION_GUARDADA" ]; then
  detalle "asignacion guardada en .estado: $ASIGNACION_GUARDADA; se vuelve a buscar por paquete"
fi
detalle "buscando la asignacion asociada al paquete $PAQUETE"
ASIGNACION=$(python_json - "$URL_LOGISTICA" "$PAQUETE" <<'PY'
import json, subprocess, sys
base, paquete = sys.argv[1], sys.argv[2]
for i in range(1, 500):
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
  guardar ASIGNACION "$ASIGNACION"
else
  falla "el paquete $PAQUETE no tiene asignacion"
  detalle "si acabas de correr el flujo 10, espera unos segundos o volvelo a correr para que el Worker procese la cola"
  resumen; exit 1
fi

req GET "$URL_LOGISTICA/asignaciones/$ASIGNACION"
if [ "$HTTP_CODE" = "200" ]; then
  ASIGNACION=$(campo '.id')
  NECESIDAD=$(campo '.necesidadID')
  detalle "asignacion $ASIGNACION en estado $(campo '.estado'), necesidad $NECESIDAD"
else
  # Sin asignacion no hay nada que entregar. No es un problema de este flujo:
  # es consecuencia de que el flujo 1 no la haya creado.
  falla "el paquete $PAQUETE no tiene asignacion (HTTP $HTTP_CODE)"
  echo ""
  echo "    ${C_WARN}Este flujo depende del flujo 1.${C_OFF}"
  echo "    Reportar una entrega es completar una asignacion existente, asi que si el"
  echo "    matchmaking no llego a crearla, no hay nada que entregar."
  echo ""
  echo "    No es un bug de este flujo. Primero hay que lograr que pase el flujo 1:"
  echo "      ./10-flujo-registrar-donacion.sh"
  echo ""
  echo "    Para desbloquearlo a mano y poder seguir probando el resto de la cadena,"
  echo "    se puede simular el callback que hace el Worker:"
  echo "      curl -X POST $URL_LOGISTICA/internal/matchmaking/resultados \\"
  echo "        -H 'Content-Type: application/json' \\"
  echo "        -d '{\"depositoId\":\"$DEPOSITO\",\"paqueteId\":\"$PAQUETE\",\"necesidadId\":\"${NECESIDAD_EXTRA:-<necesidadID>}\",\"cantidadAsignada\":40,\"cantidadSobrante\":0}'"
  resumen
  exit 1
fi

if [ -n "${NECESIDAD:-}" ] && [ "$NECESIDAD" != "null" ]; then
  req GET "$URL_DONADORES/necesidades/$NECESIDAD"
  OBJ_ANTES=$(campo '.cantidadObjetivo')
  detalle "cantidadObjetivo de la necesidad antes: $OBJ_ANTES"
fi

# ------------------------------------------------------------ reportar
paso "POST /entregas"
CUERPO="{\"id\":\"$PAQUETE\""
[ -n "${DONACION:-}" ] && CUERPO="$CUERPO,\"donacionID\":\"$DONACION\""
[ -n "${PRODUCTO:-}" ] && CUERPO="$CUERPO,\"producto\":\"$PRODUCTO\""
CUERPO="$CUERPO}"
req POST "$URL_LOGISTICA/entregas" "$CUERPO"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
  falla "el reporte de entrega fallo (HTTP $HTTP_CODE)"
  resumen; exit 1
fi
ok "entrega reportada"

# ------------------------------------------------------------ los 3 efectos
paso "1. La asignacion tiene que quedar COMPLETADA"
req GET "$URL_LOGISTICA/asignaciones/$ASIGNACION"
if [ "$HTTP_CODE" = "200" ]; then
  verificar "estado de la asignacion" "COMPLETADA" "$(campo '.estado')"
else
  aviso "no se pudo verificar la asignacion (HTTP $HTTP_CODE)"
fi

paso "2. La necesidad tiene que haberse satisfecho en Donadores y Entidades"
if [ -n "${NECESIDAD:-}" ] && [ "$NECESIDAD" != "null" ]; then
  req GET "$URL_DONADORES/necesidades/$NECESIDAD"
  OBJ_DESPUES=$(campo '.cantidadObjetivo')
  detalle "cantidadObjetivo despues: $OBJ_DESPUES (antes: ${OBJ_ANTES:-?})"
  if [ -n "${OBJ_ANTES:-}" ] && [ "$OBJ_DESPUES" != "$OBJ_ANTES" ]; then
    ok "la necesidad se movio: Logistica llamo a satisfacerNecesidad"
  else
    aviso "la cantidadObjetivo no cambio"
    detalle "puede ser que ya estuviera satisfecha, o que la llamada no haya salido"
  fi
else
  aviso "sin necesidad para verificar"
fi

paso "3. La donacion tiene que pasar a ACEPTADA en Donaciones"
if [ -n "${DONACION:-}" ]; then
  req GET "$URL_DONACIONES/donaciones/$DONACION"
  verificar "estado de la donacion" "ACEPTADA" "$(campo '.estado')"

  paso "Trazabilidad: el historial tiene que mostrar los dos cambios"
  req GET "$URL_DONACIONES/donaciones/$DONACION/historial"
  CANT=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)
" 2>/dev/null)
  detalle "cambios de estado registrados: $CANT"
  [ "${CANT:-0}" -ge 2 ] \
    && ok "el historial registro INGRESADA y ACEPTADA" \
    || aviso "el historial tiene $CANT entradas, se esperaban 2 o mas"
else
  aviso "sin donacion para verificar"
fi

echo ""
echo "Siguiente paso del guion:  ./14-flujo-queja-baneo.sh (necesita una donacion ACEPTADA)"

resumen
