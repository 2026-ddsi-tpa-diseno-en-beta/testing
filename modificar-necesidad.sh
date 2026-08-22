#!/usr/bin/env bash
# Modifica una necesidad existente y muestra antes/despues campo por campo.
#
# Uso:
#   ./modificar-necesidad.sh [extra|recurrente|stock|id] --cantidad 45
#   ./modificar-necesidad.sh extra --descripcion "Nueva descripcion" --cantidad 30
#   ./modificar-necesidad.sh --necesidad <id> --tipo RECURRENTE --urgencia 8
#   ./modificar-necesidad.sh extra --cantidad 30 --dry-run
#
# Nota: en la API actual nivelDeUrgencia puede no modificarse por PUT. Si pasa,
# el script lo informa como AVISO y deja claro que otros campos si cambiaron.
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"
exigir_json

NECESIDAD_ARG=""
ENTIDAD_ARG=""
PRODUCTO_ARG=""
DESCRIPCION_ARG=""
CANTIDAD_ARG=""
URGENCIA_ARG=""
TIPO_ARG=""
DRY_RUN="no"

CAMBIA_ENTIDAD="no"
CAMBIA_PRODUCTO="no"
CAMBIA_DESCRIPCION="no"
CAMBIA_CANTIDAD="no"
CAMBIA_URGENCIA="no"
CAMBIA_TIPO="no"

resolver_necesidad() {
  case "${1:-extra}" in
    ""|extra|extraordinaria) printf '%s' "${NECESIDAD_EXTRA:-${NECESIDAD:-}}" ;;
    recurrente)             printf '%s' "${NECESIDAD_RECURRENTE:-}" ;;
    stock)                  printf '%s' "${NECESIDAD_STOCK:-}" ;;
    manual)                 printf '%s' "${NECESIDAD_MANUAL:-${NECESIDAD:-}}" ;;
    *)                      printf '%s' "$1" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --necesidad) [ $# -ge 2 ] || { echo "Falta valor para --necesidad" >&2; exit 1; }
                  NECESIDAD_ARG="$2"; shift 2 ;;
    --necesidad=*) NECESIDAD_ARG="${1#*=}"; shift ;;
    --entidad) [ $# -ge 2 ] || { echo "Falta valor para --entidad" >&2; exit 1; }
               ENTIDAD_ARG="$2"; CAMBIA_ENTIDAD="si"; shift 2 ;;
    --entidad=*) ENTIDAD_ARG="${1#*=}"; CAMBIA_ENTIDAD="si"; shift ;;
    --producto) [ $# -ge 2 ] || { echo "Falta valor para --producto" >&2; exit 1; }
                PRODUCTO_ARG="$2"; CAMBIA_PRODUCTO="si"; shift 2 ;;
    --producto=*) PRODUCTO_ARG="${1#*=}"; CAMBIA_PRODUCTO="si"; shift ;;
    --descripcion) [ $# -ge 2 ] || { echo "Falta valor para --descripcion" >&2; exit 1; }
                   DESCRIPCION_ARG="$2"; CAMBIA_DESCRIPCION="si"; shift 2 ;;
    --descripcion=*) DESCRIPCION_ARG="${1#*=}"; CAMBIA_DESCRIPCION="si"; shift ;;
    --cantidad) [ $# -ge 2 ] || { echo "Falta valor para --cantidad" >&2; exit 1; }
                CANTIDAD_ARG="$2"; CAMBIA_CANTIDAD="si"; shift 2 ;;
    --cantidad=*) CANTIDAD_ARG="${1#*=}"; CAMBIA_CANTIDAD="si"; shift ;;
    --urgencia) [ $# -ge 2 ] || { echo "Falta valor para --urgencia" >&2; exit 1; }
                URGENCIA_ARG="$2"; CAMBIA_URGENCIA="si"; shift 2 ;;
    --urgencia=*) URGENCIA_ARG="${1#*=}"; CAMBIA_URGENCIA="si"; shift ;;
    --tipo) [ $# -ge 2 ] || { echo "Falta valor para --tipo" >&2; exit 1; }
            TIPO_ARG="$2"; CAMBIA_TIPO="si"; shift 2 ;;
    --tipo=*) TIPO_ARG="${1#*=}"; CAMBIA_TIPO="si"; shift ;;
    --dry-run) DRY_RUN="si"; shift ;;
    -h|--help|help|ayuda) ayuda --help ;;
    *) [ -z "$NECESIDAD_ARG" ] || { echo "Argumento repetido: $1" >&2; exit 1; }
       NECESIDAD_ARG="$1"; shift ;;
  esac
done

NECESIDAD=$(resolver_necesidad "$NECESIDAD_ARG")
[ -n "$NECESIDAD" ] || { echo "Falta necesidad. Corre ./01-seed.sh o pasa un ID." >&2; exit 1; }

titulo "MODIFICAR NECESIDAD"
echo "necesidad: $NECESIDAD" >&2
[ "$DRY_RUN" = "si" ] && aviso "dry-run activo: no se escribe nada"

paso "Estado antes"
req GET "$URL_DONADORES/necesidades/$NECESIDAD"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo leer la necesidad (HTTP $HTTP_CODE)"
  resumen; exit 1
fi

ENTIDAD_ANTES=$(campo '.entidadID')
PRODUCTO_ANTES=$(campo '.productoSolicitadoID')
DESCRIPCION_ANTES=$(campo '.descripcion')
CANTIDAD_ANTES=$(campo '.cantidadObjetivo')
URGENCIA_ANTES=$(campo '.nivelDeUrgencia')
TIPO_ANTES=$(campo '.tipo')

printf "  %-20s %s\n" "entidadID:" "$ENTIDAD_ANTES" >&2
printf "  %-20s %s\n" "productoSolicitadoID:" "$PRODUCTO_ANTES" >&2
printf "  %-20s %s\n" "descripcion:" "$DESCRIPCION_ANTES" >&2
printf "  %-20s %s\n" "cantidadObjetivo:" "$CANTIDAD_ANTES" >&2
printf "  %-20s %s\n" "nivelDeUrgencia:" "$URGENCIA_ANTES" >&2
printf "  %-20s %s\n" "tipo:" "$TIPO_ANTES" >&2

ENTIDAD_NUEVA="${ENTIDAD_ARG:-$ENTIDAD_ANTES}"
PRODUCTO_NUEVO="${PRODUCTO_ARG:-$PRODUCTO_ANTES}"
DESCRIPCION_NUEVA="${DESCRIPCION_ARG:-$DESCRIPCION_ANTES}"
CANTIDAD_NUEVA="${CANTIDAD_ARG:-$CANTIDAD_ANTES}"
URGENCIA_NUEVA="${URGENCIA_ARG:-$URGENCIA_ANTES}"
TIPO_NUEVO="${TIPO_ARG:-$TIPO_ANTES}"

case "$CANTIDAD_NUEVA" in
  ''|*[!0-9]*) echo "Cantidad invalida: '$CANTIDAD_NUEVA'" >&2; exit 1 ;;
esac
case "$URGENCIA_NUEVA" in
  ''|*[!0-9]*) echo "Urgencia invalida: '$URGENCIA_NUEVA'" >&2; exit 1 ;;
esac
case "$TIPO_NUEVO" in
  EXTRAORDINARIA|RECURRENTE) ;;
  *) echo "Tipo invalido: '$TIPO_NUEVO'. Usa EXTRAORDINARIA o RECURRENTE." >&2; exit 1 ;;
esac

paso "PUT /necesidades/{id}"
DESC_JSON=$(json_escape "$DESCRIPCION_NUEVA")
BODY="{\"entidadID\":\"$ENTIDAD_NUEVA\",\"productoSolicitadoID\":\"$PRODUCTO_NUEVO\",\"descripcion\":\"$DESC_JSON\",\"cantidadObjetivo\":$CANTIDAD_NUEVA,\"nivelDeUrgencia\":$URGENCIA_NUEVA,\"tipo\":\"$TIPO_NUEVO\"}"

if [ "$DRY_RUN" = "si" ]; then
  detalle "$BODY"
  ok "dry-run: request armado"
  resumen; exit $?
fi

req PUT "$URL_DONADORES/necesidades/$NECESIDAD" "$BODY"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo modificar la necesidad (HTTP $HTTP_CODE)"
  resumen; exit 1
fi
ok "PUT respondio 200"

paso "Estado despues"
req GET "$URL_DONADORES/necesidades/$NECESIDAD"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo leer la necesidad despues (HTTP $HTTP_CODE)"
  resumen; exit 1
fi

comparar_cambio() {
  local nombre="$1" antes="$2" esperado="$3" obtenido="$4" pidio="$5"
  printf "  %-20s %s -> %s\n" "$nombre:" "$antes" "$obtenido" >&2
  if [ "$pidio" = "si" ]; then
    if [ "$esperado" = "$obtenido" ]; then
      ok "$nombre modificado"
    else
      aviso "$nombre no quedo como se pidio; esperado $esperado, obtenido $obtenido"
    fi
  fi
}

comparar_cambio "entidadID" "$ENTIDAD_ANTES" "$ENTIDAD_NUEVA" "$(campo '.entidadID')" "$CAMBIA_ENTIDAD"
comparar_cambio "productoSolicitadoID" "$PRODUCTO_ANTES" "$PRODUCTO_NUEVO" "$(campo '.productoSolicitadoID')" "$CAMBIA_PRODUCTO"
comparar_cambio "descripcion" "$DESCRIPCION_ANTES" "$DESCRIPCION_NUEVA" "$(campo '.descripcion')" "$CAMBIA_DESCRIPCION"
comparar_cambio "cantidadObjetivo" "$CANTIDAD_ANTES" "$CANTIDAD_NUEVA" "$(campo '.cantidadObjetivo')" "$CAMBIA_CANTIDAD"
comparar_cambio "nivelDeUrgencia" "$URGENCIA_ANTES" "$URGENCIA_NUEVA" "$(campo '.nivelDeUrgencia')" "$CAMBIA_URGENCIA"
comparar_cambio "tipo" "$TIPO_ANTES" "$TIPO_NUEVO" "$(campo '.tipo')" "$CAMBIA_TIPO"

guardar NECESIDAD_MANUAL "$NECESIDAD"

echo "" >&2
echo "  Para ver el detalle:" >&2
echo "    ./ver-estado.sh necesidad $NECESIDAD --json" >&2

resumen
