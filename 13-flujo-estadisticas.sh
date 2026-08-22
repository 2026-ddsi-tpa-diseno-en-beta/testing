#!/usr/bin/env bash
# FLUJO 4 - CONSULTAR LAS ESTADISTICAS DE UN DONADOR
#
# El enunciado define la interaccion Donadores y Entidades -> Incentivos: al pedir las
# estadisticas de un donador, Donadores tiene que consultarle a Incentivos sus insignias
# y su mision en curso.
#
# Este script compara las dos fuentes: lo que dice Incentivos y lo que reporta Donadores.
# Si Incentivos tiene datos y Donadores devuelve vacio, la integracion no esta ocurriendo.
set -u
. "$(dirname "$0")/lib/comun.sh"

exigir_estado DONADOR_OK
DONADOR="${1:-$DONADOR_OK}"

titulo "FLUJO 4 - ESTADISTICAS DE UN DONADOR"
echo "donador: $DONADOR"

# Para que la comparacion sirva de algo, el donador tiene que tener al menos una insignia
# en Incentivos. Si no tiene, se le asigna una: es la unica forma de distinguir
# "la integracion no anda" de "no hay nada que traer".
paso "0. Precondicion: que el donador tenga alguna insignia en Incentivos"
req GET "$URL_INCENTIVOS/insignias/donador/$DONADOR"
YA_TIENE=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 0)
except Exception: print(0)
" 2>/dev/null)

if [ "${YA_TIENE:-0}" -eq 0 ] && [ -n "${INSIGNIA:-}" ]; then
  detalle "no tiene ninguna, se le asigna la insignia $INSIGNIA"
  req GET "$URL_INCENTIVOS/insignias/$INSIGNIA"
  if [ "$HTTP_CODE" = "200" ]; then
    req POST "$URL_INCENTIVOS/insignias/donador/$DONADOR" "$HTTP_BODY"
    case "$HTTP_CODE" in
      200|201|204) ok "insignia asignada" ;;
      *)           aviso "no se pudo asignar la insignia (HTTP $HTTP_CODE)" ;;
    esac
  fi
else
  detalle "ya tiene ${YA_TIENE:-0} insignia(s)"
fi

paso "1. Lo que dice INCENTIVOS (la fuente de verdad de insignias y misiones)"
req GET "$URL_INCENTIVOS/insignias/donador/$DONADOR"
INSIG_INC="$HTTP_BODY"
COD_INSIG="$HTTP_CODE"
CANT_INC=$(printf '%s' "$INSIG_INC" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 0)
except Exception: print(0)
" 2>/dev/null)
detalle "insignias segun Incentivos: ${CANT_INC:-0} (HTTP $COD_INSIG)"

req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR"
detalle "mision segun Incentivos: HTTP $HTTP_CODE"
MISION_INC=$(campo '.id')
[ -n "$MISION_INC" ] && [ "$MISION_INC" != "null" ] && detalle "   mision id: $MISION_INC"

paso "2. Lo que reporta DONADORES Y ENTIDADES en /estadisticas"
req GET "$URL_DONADORES/donadores/$DONADOR/estadisticas"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo leer las estadisticas (HTTP $HTTP_CODE)"
  resumen; exit 1
fi
ok "estadisticas respondidas"
detalle "estado:     $(campo '.estado')"
detalle "categoria:  $(campo '.categoria')"
detalle "mision:     $(campo '.misionActualID')"

CANT_DYE=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get('insigniasID') or []
    print(len(v))
except Exception: print(0)
" 2>/dev/null)
detalle "insignias:  ${CANT_DYE:-0}"

paso "3. Comparacion de las dos fuentes"
if [ "${CANT_INC:-0}" -gt 0 ] && [ "${CANT_DYE:-0}" -eq 0 ]; then
  falla "Incentivos tiene ${CANT_INC} insignia(s) pero /estadisticas devuelve la lista vacia"
  echo ""
  echo "    ${C_WARN}La integracion Donadores -> Incentivos no esta funcionando.${C_OFF}"
  echo "    Que revisar en el modulo de Donadores y Entidades:"
  echo "    - Que URL_INCENTIVOS este configurada en Render."
  echo "    - Que las rutas coincidan. Incentivos expone:"
  echo "         GET /insignias/donador/{id}"
  echo "         GET /misiones/donador/{id}"
  echo "      Si el cliente llama a /donadores/{id}/insignias, da 404 y el catch"
  echo "      lo convierte en lista vacia sin avisar."
  echo "    - Que getMisionEnCursoDeDonador este implementado y no devuelva null fijo."
elif [ "${CANT_INC:-0}" -gt 0 ] && [ "${CANT_DYE:-0}" -gt 0 ]; then
  verificar "cantidad de insignias en las dos fuentes" "$CANT_INC" "$CANT_DYE"
  ok "la integracion Donadores -> Incentivos funciona"
elif [ "${CANT_INC:-0}" -eq 0 ]; then
  aviso "el donador no tiene insignias en Incentivos, no hay nada que comparar"
  detalle "corre primero ./12-flujo-procesar-donador.sh para que gane alguna"
fi

resumen
