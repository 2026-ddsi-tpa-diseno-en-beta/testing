#!/usr/bin/env bash
# Crea UNA entidad benefica.
#
# Uso:
#   ./crear-entidad.sh
#   ./crear-entidad.sh --razon "Comedor Hogwarts"
#   ./crear-entidad.sh --razon "Comedor Hogwarts" --domicilio "Av. Siempreviva 742" \
#                      --telefono 1145678900 --correo contacto@hogwarts.org
#   ./crear-entidad.sh --razon "Comedor X" --guardar-como ENTIDAD_DEMO
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

RAZON=""; DOMICILIO=""; TELEFONO=""; CORREO=""; GUARDAR_COMO="ENTIDAD"

while [ $# -gt 0 ]; do
  case "$1" in
    --razon)         RAZON="$2"; shift 2 ;;
    --domicilio)     DOMICILIO="$2"; shift 2 ;;
    --telefono)      TELEFONO="$2"; shift 2 ;;
    --correo)        CORREO="$2"; shift 2 ;;
    --guardar-como)  GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-entidad.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UNA ENTIDAD BENEFICA"

SUFIJO="$(date +%H%M%S)"
preguntar RAZON     "Razon social"  "$PREFIJO-Comedor-$SUFIJO"
preguntar DOMICILIO "Domicilio"     "Av. de prueba 742"
preguntar TELEFONO  "Telefono"      "1140000000"
preguntar CORREO    "Correo"        "$PREFIJO-$SUFIJO@entidad.test"

paso "POST /entidades"
req POST "$URL_DONADORES/entidades" \
  "{\"razonSocial\":\"$RAZON\",\"domicilio\":\"$DOMICILIO\",\"telefono\":\"$TELEFONO\",\"correo\":\"$CORREO\"}"

ENTIDAD_NUEVA=$(campo '.id')
creado "entidad" "$ENTIDAD_NUEVA" || { resumen; exit 1; }

guardar "$GUARDAR_COMO" "$ENTIDAD_NUEVA"

echo "" >&2
echo "  Para darle una necesidad:" >&2
echo "    ./crear-necesidad.sh --entidad $ENTIDAD_NUEVA --producto <productoID> --cantidad 100" >&2

echo "$ENTIDAD_NUEVA"
resumen
