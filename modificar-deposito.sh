#!/usr/bin/env bash
# Cambia el algoritmo de matchmaking de un deposito y muestra antes/despues.
#
# Uso:
#   ./modificar-deposito.sh --algoritmo SUB_ATENDIDOS
#   ./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE
#   ./modificar-deposito.sh --deposito <id> --algoritmo SUB_ATENDIDOS --dry-run
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"
exigir_json

DEPOSITO_ARG="${DEPOSITO:-}"
ALGORITMO_ARG=""
DRY_RUN="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --deposito) [ $# -ge 2 ] || { echo "Falta valor para --deposito" >&2; exit 1; }
                DEPOSITO_ARG="$2"; shift 2 ;;
    --deposito=*) DEPOSITO_ARG="${1#*=}"; shift ;;
    --algoritmo) [ $# -ge 2 ] || { echo "Falta valor para --algoritmo" >&2; exit 1; }
                 ALGORITMO_ARG="$2"; shift 2 ;;
    --algoritmo=*) ALGORITMO_ARG="${1#*=}"; shift ;;
    --dry-run) DRY_RUN="si"; shift ;;
    -h|--help|help|ayuda) ayuda --help ;;
    *) echo "Argumento desconocido: $1  (./modificar-deposito.sh --help)" >&2; exit 1 ;;
  esac
done

[ -n "$DEPOSITO_ARG" ] || { echo "Falta deposito. Corre ./01-seed.sh o pasa --deposito <id>." >&2; exit 1; }
[ -n "$ALGORITMO_ARG" ] || { echo "Falta --algoritmo. Usa SUB_ATENDIDOS o PRIORIDAD_POR_SCORE." >&2; exit 1; }

case "$ALGORITMO_ARG" in
  SUB_ATENDIDOS|PRIORIDAD_POR_SCORE) ;;
  *) echo "Algoritmo invalido: $ALGORITMO_ARG. Usa SUB_ATENDIDOS o PRIORIDAD_POR_SCORE." >&2; exit 1 ;;
esac

titulo "MODIFICAR ALGORITMO DEL DEPOSITO"
echo "deposito:  $DEPOSITO_ARG" >&2
echo "algoritmo: $ALGORITMO_ARG" >&2
[ "$DRY_RUN" = "si" ] && aviso "dry-run activo: no se escribe nada"

paso "Estado antes"
req GET "$URL_LOGISTICA/depositos/$DEPOSITO_ARG"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo leer el deposito (HTTP $HTTP_CODE)"
  resumen; exit 1
fi
ANTES=$(campo '.algoritmo')
printf "  algoritmo antes: %s\n" "$ANTES" >&2

paso "PATCH /depositos/{id}/algoritmo"
BODY="{\"algoritmo\":\"$ALGORITMO_ARG\"}"
if [ "$DRY_RUN" = "si" ]; then
  detalle "$BODY"
  ok "dry-run: request armado"
  resumen; exit $?
fi

req PATCH "$URL_LOGISTICA/depositos/$DEPOSITO_ARG/algoritmo" "$BODY"
case "$HTTP_CODE" in
  200|204) ok "PATCH respondio HTTP $HTTP_CODE" ;;
  *) falla "no se pudo modificar el algoritmo (HTTP $HTTP_CODE)" ;;
esac

paso "Estado despues"
req GET "$URL_LOGISTICA/depositos/$DEPOSITO_ARG"
if [ "$HTTP_CODE" = "200" ]; then
  DESPUES=$(campo '.algoritmo')
  printf "  algoritmo despues: %s\n" "$DESPUES" >&2
  verificar "algoritmo aplicado" "$ALGORITMO_ARG" "$DESPUES"
else
  falla "no se pudo verificar el deposito despues (HTTP $HTTP_CODE)"
fi

guardar DEPOSITO "$DEPOSITO_ARG"

echo "" >&2
echo "  Para explicar el impacto:" >&2
echo "    SUB_ATENDIDOS prioriza la necesidad mas alejada de completarse." >&2
echo "    PRIORIDAD_POR_SCORE pondera urgencia y proporcion de cobertura." >&2

resumen
