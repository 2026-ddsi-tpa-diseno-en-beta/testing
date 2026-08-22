#!/usr/bin/env bash
# Verifica el estado de un objeto puntual, sin correr todo el tablero.
#
# Uso:
#   ./ver-estado.sh donacion [id] [--esperado ESTADO] [--json]
#   ./ver-estado.sh donador [ok|sospechoso|casi-baneado|id] [--esperado ESTADO] [--json]
#   ./ver-estado.sh asignacion [id] [--esperado ESTADO] [--json]
#   ./ver-estado.sh necesidad [extra|recurrente|id] [--json]
#   ./ver-estado.sh stock [productoID] [--esperado CANTIDAD] [--json]
#   ./ver-estado.sh paquete [id] [--json]
#   ./ver-estado.sh deposito [id] [--json]
#
# Si no pasas un id, usa los IDs guardados por los scripts en .estado.
set -u
. "$(dirname "$0")/lib/comun.sh"

ayuda "${1:-}"

uso() {
  sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d' >&2
  exit "${1:-1}"
}

[ $# -gt 0 ] || uso 1

TIPO="$1"
shift

ID=""
ESPERADO=""
CAMPO=""
MOSTRAR_JSON="no"
JSON_SALIDA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --esperado)
      [ $# -ge 2 ] || uso 1
      ESPERADO="$2"
      shift 2
      ;;
    --campo)
      [ $# -ge 2 ] || uso 1
      CAMPO="$2"
      shift 2
      ;;
    --json)
      MOSTRAR_JSON="si"
      shift
      ;;
    -h|--help|help|ayuda)
      uso 0
      ;;
    *)
      [ -z "$ID" ] || uso 1
      ID="$1"
      shift
      ;;
  esac
done

resolver_donador() {
  case "${1:-ok}" in
    ""|ok|limpio|verificado) printf '%s' "${DONADOR_OK:-}" ;;
    sospechoso)              printf '%s' "${DONADOR_SOSPECHOSO:-}" ;;
    casi|casi-baneado)       printf '%s' "${DONADOR_CASI_BANEADO:-}" ;;
    *)                       printf '%s' "$1" ;;
  esac
}

resolver_necesidad() {
  case "${1:-extra}" in
    ""|extra|extraordinaria) printf '%s' "${NECESIDAD_EXTRA:-}" ;;
    recurrente)             printf '%s' "${NECESIDAD_RECURRENTE:-}" ;;
    *)                      printf '%s' "$1" ;;
  esac
}

mostrar_campos() {
  local titulo_objeto="$1"
  shift
  printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
titulo = sys.argv[1]
campos = sys.argv[2:]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()
if isinstance(data, list):
    print(f"  {titulo}: {len(data)} elementos")
    return_data = data[:5]
else:
    return_data = [data]
for item in return_data:
    for campo in campos:
        valor = item.get(campo, "-")
        print(f"  {campo}: {valor}")
    if len(return_data) > 1:
        print("")
' "$titulo_objeto" "$@" >&2 2>/dev/null
}

contar_json() {
  printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 1)
except Exception:
    print(0)
" 2>/dev/null
}

mostrar_historial_donacion() {
  local donacion="$1"
  paso "Historial de la donacion"
  req GET "$URL_DONACIONES/donaciones/$donacion/historial"
  if [ "$HTTP_CODE" = "200" ]; then
    printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()
if not isinstance(data, list):
    data = [data]
print(f"  cambios registrados: {len(data)}")
for item in data[-6:]:
    estado = item.get("estado") or item.get("estadoNuevo") or item.get("nuevoEstado") or "-"
    fecha = item.get("fecha") or item.get("fechaCambio") or item.get("createdAt") or "-"
    print(f"  - {estado}  {fecha}")
' >&2 2>/dev/null
  else
    aviso "no se pudo leer el historial (HTTP $HTTP_CODE)"
  fi
}

mostrar_estado_donador() {
  local donador="$1"
  paso "Puede donar"
  req GET "$URL_DONADORES/donadores/$donador/puede-donar"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  puede-donar: $(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')" >&2
  else
    aviso "no se pudo leer puede-donar (HTTP $HTTP_CODE)"
  fi

  paso "Quejas del donador"
  req GET "$URL_DONADORES/donadores/$donador/quejas"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  quejas: $(contar_json)" >&2
  else
    aviso "no se pudieron leer las quejas (HTTP $HTTP_CODE)"
  fi
}

mostrar_json_completo() {
  local cuerpo="${1:-$HTTP_BODY}"
  if [ "$MOSTRAR_JSON" = "si" ]; then
    paso "JSON completo"
    printf '%s\n' "$cuerpo" >&2
  fi
}

validar_esperado() {
  local descripcion="$1" esperado="$2" obtenido="$3"
  if [ -n "$esperado" ]; then
    verificar "$descripcion" "$esperado" "$obtenido"
  fi
}

case "$TIPO" in
  donacion)
    ID="${ID:-${DONACION:-}}"
    [ -n "$ID" ] || { echo "Falta id de donacion. Corre ./10-flujo-registrar-donacion.sh o pasa el id." >&2; exit 1; }
    CAMPO="${CAMPO:-.estado}"
    titulo "ESTADO PUNTUAL - DONACION"
    req GET "$URL_DONACIONES/donaciones/$ID"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer la donacion $ID"; resumen; exit 1; }
    JSON_SALIDA="$HTTP_BODY"
    VALOR=$(campo "$CAMPO")
    mostrar_campos "donacion" id donadorID productoID cantidad estado
    ok "donacion leida correctamente"
    validar_esperado "$CAMPO de la donacion" "$ESPERADO" "$VALOR"
    mostrar_historial_donacion "$ID"
    ;;

  donador)
    ID=$(resolver_donador "$ID")
    [ -n "$ID" ] || { echo "Falta id de donador. Corre ./01-seed.sh o pasa el id." >&2; exit 1; }
    CAMPO="${CAMPO:-.estado}"
    titulo "ESTADO PUNTUAL - DONADOR"
    req GET "$URL_DONADORES/donadores/$ID"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer el donador $ID"; resumen; exit 1; }
    JSON_SALIDA="$HTTP_BODY"
    VALOR=$(campo "$CAMPO")
    mostrar_campos "donador" id nombre apellido email estado categoria
    ok "donador leido correctamente"
    validar_esperado "$CAMPO del donador" "$ESPERADO" "$VALOR"
    mostrar_estado_donador "$ID"
    ;;

  asignacion)
    ID="${ID:-${ASIGNACION:-}}"
    [ -n "$ID" ] || { echo "Falta id de asignacion. Corre ./10-flujo-registrar-donacion.sh o pasa el id." >&2; exit 1; }
    CAMPO="${CAMPO:-.estado}"
    titulo "ESTADO PUNTUAL - ASIGNACION"
    req GET "$URL_LOGISTICA/asignaciones/$ID"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer la asignacion $ID"; resumen; exit 1; }
    JSON_SALIDA="$HTTP_BODY"
    VALOR=$(campo "$CAMPO")
    mostrar_campos "asignacion" id paqueteID necesidadID cantidadAsignada estado
    ok "asignacion leida correctamente"
    validar_esperado "$CAMPO de la asignacion" "$ESPERADO" "$VALOR"
    ;;

  necesidad)
    ID=$(resolver_necesidad "$ID")
    [ -n "$ID" ] || { echo "Falta id de necesidad. Corre ./01-seed.sh o pasa el id." >&2; exit 1; }
    CAMPO="${CAMPO:-.cantidadObjetivo}"
    titulo "ESTADO PUNTUAL - NECESIDAD"
    req GET "$URL_DONADORES/necesidades/$ID"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer la necesidad $ID"; resumen; exit 1; }
    JSON_SALIDA="$HTTP_BODY"
    VALOR=$(campo "$CAMPO")
    mostrar_campos "necesidad" id tipo cantidadObjetivo productoSolicitadoID nivelDeUrgencia entidadID
    ok "necesidad leida correctamente"
    validar_esperado "$CAMPO de la necesidad" "$ESPERADO" "$VALOR"
    ;;

  stock)
    ID="${ID:-${PRODUCTO:-}}"
    [ -n "$ID" ] || { echo "Falta productoID. Corre ./01-seed.sh o pasa el id del producto." >&2; exit 1; }
    CAMPO="${CAMPO:-.cantidadDisponible}"
    titulo "ESTADO PUNTUAL - STOCK"
    req GET "$URL_LOGISTICA/stock/$ID"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer el stock del producto $ID"; resumen; exit 1; }
    JSON_SALIDA="$HTTP_BODY"
    VALOR=$(campo "$CAMPO")
    mostrar_campos "stock" productoId cantidadDisponible
    ok "stock leido correctamente"
    validar_esperado "$CAMPO del stock" "$ESPERADO" "$VALOR"
    ;;

  paquete)
    ID="${ID:-${PAQUETE:-}}"
    [ -n "$ID" ] || { echo "Falta paqueteID. Corre ./10-flujo-registrar-donacion.sh o pasa el id." >&2; exit 1; }
    [ -n "${DEPOSITO:-}" ] || { echo "Falta DEPOSITO en .estado para buscar el paquete." >&2; exit 1; }
    titulo "ESTADO PUNTUAL - PAQUETE"
    req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer el deposito $DEPOSITO"; resumen; exit 1; }
    PAQUETE_JSON=$(printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
paquete = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()
for item in data.get("stockActual") or []:
    if str(item.get("id")) == str(paquete):
        print(json.dumps(item, ensure_ascii=False))
        break
' "$ID" 2>/dev/null
)
    if [ -n "$PAQUETE_JSON" ]; then
      HTTP_BODY="$PAQUETE_JSON"
      JSON_SALIDA="$HTTP_BODY"
      mostrar_campos "paquete" id donacionID producto cantidad
      ok "paquete encontrado en el deposito $DEPOSITO"
    else
      falla "el paquete $ID no aparece en el deposito $DEPOSITO"
    fi
    ;;

  deposito)
    ID="${ID:-${DEPOSITO:-}}"
    [ -n "$ID" ] || { echo "Falta depositoID. Corre ./01-seed.sh o pasa el id." >&2; exit 1; }
    titulo "ESTADO PUNTUAL - DEPOSITO"
    req GET "$URL_LOGISTICA/depositos/$ID"
    [ "$HTTP_CODE" = "200" ] || { falla "no se pudo leer el deposito $ID"; resumen; exit 1; }
    JSON_SALIDA="$HTTP_BODY"
    mostrar_campos "deposito" id nombre capacidadMaxima algoritmo
    ok "deposito leido correctamente"
    ;;

  *)
    uso 1
    ;;
esac

mostrar_json_completo "${JSON_SALIDA:-$HTTP_BODY}"
resumen
