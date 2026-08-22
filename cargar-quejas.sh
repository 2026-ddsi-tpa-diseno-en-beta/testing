#!/usr/bin/env bash
# Carga quejas a un donador y muestra como cambian su cantidad de quejas, estado
# y puede-donar. Sirve para responder preguntas sobre VERIFICADO/SOSPECHOSO/BANEADO.
#
# Modos:
#   directo a Donadores:
#     ./cargar-quejas.sh [ok|sospechoso|casi-baneado|manual|id] --cantidad 1
#
#   via Donaciones, sobre una donacion real aceptada:
#     ./cargar-quejas.sh --via-donaciones --donacion <id>
#
# Opciones:
#   --donador <id|alias>      alias: ok, sospechoso, casi-baneado, manual, demo
#   --donacion <id>           donacion asociada a la queja; default: manual
#   --cantidad <n>            cantidad de quejas; default: 1
#   --descripcion <texto>     texto de la queja
#   --dry-run                 no escribe nada, solo muestra que haria
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"
exigir_json

DONADOR_ARG=""
DONACION_ARG=""
CANTIDAD="1"
DESCRIPCION="queja cargada durante demo"
VIA_DONACIONES="no"
DRY_RUN="no"

resolver_donador() {
  case "${1:-ok}" in
    ""|ok|limpio|verificado) printf '%s' "${DONADOR_OK:-}" ;;
    sospechoso)              printf '%s' "${DONADOR_SOSPECHOSO:-}" ;;
    casi|casi-baneado)       printf '%s' "${DONADOR_CASI_BANEADO:-}" ;;
    manual)                  printf '%s' "${DONADOR_MANUAL:-${DONADOR_CREAR_TEST:-}}" ;;
    demo)                    printf '%s' "${DONADOR_DEMO:-}" ;;
    *)                       printf '%s' "$1" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --donador) [ $# -ge 2 ] || { echo "Falta valor para --donador" >&2; exit 1; }
               DONADOR_ARG="$2"; shift 2 ;;
    --donador=*) DONADOR_ARG="${1#*=}"; shift ;;
    --donacion) [ $# -ge 2 ] || { echo "Falta valor para --donacion" >&2; exit 1; }
                DONACION_ARG="$2"; shift 2 ;;
    --donacion=*) DONACION_ARG="${1#*=}"; shift ;;
    --cantidad) [ $# -ge 2 ] || { echo "Falta valor para --cantidad" >&2; exit 1; }
                CANTIDAD="$2"; shift 2 ;;
    --cantidad=*) CANTIDAD="${1#*=}"; shift ;;
    --descripcion) [ $# -ge 2 ] || { echo "Falta valor para --descripcion" >&2; exit 1; }
                   DESCRIPCION="$2"; shift 2 ;;
    --descripcion=*) DESCRIPCION="${1#*=}"; shift ;;
    --via-donaciones) VIA_DONACIONES="si"; shift ;;
    --dry-run) DRY_RUN="si"; shift ;;
    -h|--help|help|ayuda) ayuda --help ;;
    *) [ -z "$DONADOR_ARG" ] || { echo "Argumento repetido: $1" >&2; exit 1; }
       DONADOR_ARG="$1"; shift ;;
  esac
done

case "$CANTIDAD" in
  ''|*[!0-9]*) echo "Cantidad invalida: '$CANTIDAD'" >&2; exit 1 ;;
esac

DONADOR=$(resolver_donador "$DONADOR_ARG")
DONACION="${DONACION_ARG:-manual}"

if [ "$VIA_DONACIONES" = "si" ]; then
  DONACION="${DONACION_ARG:-${DONACION:-}}"
  [ -n "$DONACION" ] && [ "$DONACION" != "manual" ] || {
    echo "Para --via-donaciones necesito una donacion real: --donacion <id>" >&2
    exit 1
  }
  req GET "$URL_DONACIONES/donaciones/$DONACION" >/dev/null 2>&1
  if [ "$HTTP_CODE" != "200" ]; then
    falla "no pude leer la donacion $DONACION (HTTP $HTTP_CODE)"
    resumen; exit 1
  fi
  DONADOR="${DONADOR:-$(campo '.donadorID')}"
  ESTADO_DONACION=$(campo '.estado')
  if [ "$ESTADO_DONACION" != "ACEPTADA" ]; then
    aviso "la donacion esta en $ESTADO_DONACION; Donaciones normalmente acepta quejas solo sobre ACEPTADA"
  fi
  if [ "$CANTIDAD" -gt 1 ]; then
    aviso "--via-donaciones suele servir para una sola queja por donacion; si queres subir umbrales usa modo directo"
  fi
fi

[ -n "$DONADOR" ] || { echo "Falta donador. Corre ./01-seed.sh o pasa --donador <id>." >&2; exit 1; }

estado_donador() {
  local etiqueta="$1"
  req GET "$URL_DONADORES/donadores/$DONADOR" >/dev/null 2>&1
  ESTADO_ACTUAL="$(campo '.estado')"
  req GET "$URL_DONADORES/donadores/$DONADOR/quejas" >/dev/null 2>&1
  QUEJAS_ACTUALES=$(printf '%s' "$HTTP_BODY" | python_json -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else 1)
except Exception:
    print(0)
' 2>/dev/null)
  req GET "$URL_DONADORES/donadores/$DONADOR/puede-donar" >/dev/null 2>&1
  PUEDE_ACTUAL=$(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')
  printf "  %-10s quejas=%-3s estado=%-12s puede-donar=%s\n" \
    "$etiqueta" "${QUEJAS_ACTUALES:-0}" "$ESTADO_ACTUAL" "$PUEDE_ACTUAL" >&2
}

titulo "CARGAR QUEJAS A UN DONADOR"
echo "donador:  $DONADOR" >&2
echo "donacion: $DONACION" >&2
echo "cantidad: $CANTIDAD" >&2
[ "$DRY_RUN" = "si" ] && aviso "dry-run activo: no se escribe nada"

paso "Estado antes"
estado_donador "ANTES"

DESC_JSON=$(json_escape "$DESCRIPCION")
i=1
while [ "$i" -le "$CANTIDAD" ]; do
  paso "Queja $i de $CANTIDAD"
  if [ "$VIA_DONACIONES" = "si" ]; then
    URL="$URL_DONACIONES/donaciones/$DONACION/quejas"
    BODY="{\"descripcion\":\"$DESC_JSON\"}"
  else
    FECHA=$(date +%Y-%m-%d)
    URL="$URL_DONADORES/donadores/$DONADOR/quejas"
    BODY="{\"donacionID\":\"$DONACION\",\"donadorID\":\"$DONADOR\",\"fecha\":\"$FECHA\",\"descripcion\":\"$DESC_JSON\"}"
  fi

  if [ "$DRY_RUN" = "si" ]; then
    detalle "POST ${URL#http*//*/}"
    detalle "$BODY"
    ok "dry-run: request armado"
  else
    req POST "$URL" "$BODY"
    case "$HTTP_CODE" in
      200|201) ok "queja registrada" ;;
      *) falla "no se pudo registrar la queja (HTTP $HTTP_CODE)" ;;
    esac
  fi

  if [ "$DRY_RUN" != "si" ]; then
    estado_donador "DESPUES"
  fi
  i=$((i + 1))
done

if [ "$DRY_RUN" != "si" ]; then
  guardar DONADOR_QUEJAS "$DONADOR"
  echo "" >&2
  echo "  Para explicar el estado final:" >&2
  echo "    ./ver-donador.sh $DONADOR --detalle" >&2
fi

resumen
