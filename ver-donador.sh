#!/usr/bin/env bash
# Muestra todo lo que normalmente preguntan sobre un donador:
# estado, si puede donar, quejas, estadisticas y cantidad de donaciones por estado.
#
# Uso:
#   ./ver-donador.sh [ok|sospechoso|casi-baneado|manual|mision|id] [--detalle] [--json]
#   ./ver-donador.sh --donador <id> --detalle
#
# Si no pasas donador, usa DONADOR_OK de .estado.
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"
exigir_json

DONADOR_ARG=""
DETALLE="no"
MOSTRAR_JSON="no"

resolver_donador() {
  case "${1:-ok}" in
    ""|ok|limpio|verificado) printf '%s' "${DONADOR_OK:-}" ;;
    sospechoso)              printf '%s' "${DONADOR_SOSPECHOSO:-}" ;;
    casi|casi-baneado)       printf '%s' "${DONADOR_CASI_BANEADO:-}" ;;
    manual)                  printf '%s' "${DONADOR_MANUAL:-${DONADOR_CREAR_TEST:-}}" ;;
    demo)                    printf '%s' "${DONADOR_DEMO:-}" ;;
    mision|misiones)         printf '%s' "${DONADOR_MISION:-}" ;;
    *)                       printf '%s' "$1" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --donador) [ $# -ge 2 ] || { echo "Falta valor para --donador" >&2; exit 1; }
               DONADOR_ARG="$2"; shift 2 ;;
    --donador=*) DONADOR_ARG="${1#*=}"; shift ;;
    --detalle) DETALLE="si"; shift ;;
    --json) MOSTRAR_JSON="si"; shift ;;
    -h|--help|help|ayuda) ayuda --help ;;
    *) [ -z "$DONADOR_ARG" ] || { echo "Argumento repetido: $1" >&2; exit 1; }
       DONADOR_ARG="$1"; shift ;;
  esac
done

DONADOR=$(resolver_donador "$DONADOR_ARG")
[ -n "$DONADOR" ] || { echo "Falta donador. Corre ./01-seed.sh o pasa un ID." >&2; exit 1; }

titulo "DONADOR - ESTADO Y DONACIONES"
echo "donador: $DONADOR" >&2

paso "1. Datos del donador"
req GET "$URL_DONADORES/donadores/$DONADOR"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo leer el donador (HTTP $HTTP_CODE)"
  resumen; exit 1
fi
DONADOR_JSON="$HTTP_BODY"
ESTADO=$(campo '.estado')
printf "  %-13s %s\n" "nombre:" "$(campo '.nombre') $(campo '.apellido')" >&2
printf "  %-13s %s\n" "email:" "$(campo '.email')" >&2
printf "  %-13s %s\n" "estado:" "$ESTADO" >&2
printf "  %-13s %s\n" "categoria:" "$(campo '.categoria')" >&2
ok "donador encontrado"

paso "2. Puede donar"
req GET "$URL_DONADORES/donadores/$DONADOR/puede-donar"
if [ "$HTTP_CODE" = "200" ]; then
  PUEDE=$(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')
  printf "  puede-donar: %s\n" "$PUEDE" >&2
  case "$ESTADO:$PUEDE" in
    BANEADO:false) ok "un BANEADO no puede donar" ;;
    VERIFICADO:true) ok "un VERIFICADO puede donar" ;;
    SOSPECHOSO:*) aviso "un SOSPECHOSO puede donar solo algunas veces por regla de negocio" ;;
    *) aviso "combinacion estado/puede-donar: $ESTADO/$PUEDE" ;;
  esac
else
  aviso "no se pudo leer puede-donar (HTTP $HTTP_CODE)"
fi

paso "3. Quejas"
req GET "$URL_DONADORES/donadores/$DONADOR/quejas"
if [ "$HTTP_CODE" = "200" ]; then
  QUEJAS_JSON="$HTTP_BODY"
  QUEJAS=$(printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else 1)
except Exception:
    print(0)
' 2>/dev/null)
  printf "  quejas: %s\n" "${QUEJAS:-0}" >&2
  if [ "${QUEJAS:-0}" -ge 10 ] 2>/dev/null; then
    verificar "umbral de 10 quejas" "BANEADO" "$ESTADO"
  elif [ "${QUEJAS:-0}" -ge 5 ] 2>/dev/null; then
    verificar "umbral de 5 a 9 quejas" "SOSPECHOSO" "$ESTADO"
  else
    verificar "menos de 5 quejas" "VERIFICADO" "$ESTADO"
  fi
else
  aviso "no se pudieron leer quejas (HTTP $HTTP_CODE)"
fi

paso "4. Estadisticas"
req GET "$URL_DONADORES/donadores/$DONADOR/estadisticas"
if [ "$HTTP_CODE" = "200" ]; then
  printf "  misionActualID: %s\n" "$(campo '.misionActualID')" >&2
  printf "  insigniasID:    %s\n" "$(campo '.insigniasID')" >&2
  ok "estadisticas disponibles"
else
  aviso "no se pudieron leer estadisticas (HTTP $HTTP_CODE)"
fi

paso "5. Donaciones del donador"
req GET "$URL_DONACIONES/donaciones"
if [ "$HTTP_CODE" = "200" ]; then
  printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
from collections import Counter
donador = sys.argv[1]
detalle = sys.argv[2] == "si"
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
items = [x for x in data if str(x.get("donadorID")) == str(donador)]
print(f"  total: {len(items)}")
conteo = Counter(x.get("estado") or "sin estado" for x in items)
if conteo:
    print("  por estado: " + "  ".join(f"{k}={v}" for k, v in sorted(conteo.items())))
else:
    print("  por estado: sin donaciones")
ultimas = items[-8:] if detalle else items[-4:]
if ultimas:
    print("  ultimas:")
    for x in ultimas:
        did = x.get("id")
        producto = x.get("productoID")
        cantidad = x.get("cantidad")
        estado = x.get("estado")
        print(f"    {did}  producto={producto}  cantidad={cantidad}  estado={estado}")
' "$DONADOR" "$DETALLE" >&2 2>/dev/null
  ok "donaciones contadas desde Donaciones"
else
  aviso "no se pudo leer /donaciones (HTTP $HTTP_CODE)"
fi

if [ "$MOSTRAR_JSON" = "si" ]; then
  paso "JSON del donador"
  printf '%s\n' "$DONADOR_JSON" >&2
  if [ -n "${QUEJAS_JSON:-}" ]; then
    paso "JSON de quejas"
    printf '%s\n' "$QUEJAS_JSON" >&2
  fi
fi

echo "" >&2
echo "  Para cargarle una queja:" >&2
echo "    ./cargar-quejas.sh --donador $DONADOR --cantidad 1" >&2
echo "  Para usarlo en una donacion:" >&2
echo "    ./donar.sh --donador $DONADOR --cantidad 10" >&2

resumen
