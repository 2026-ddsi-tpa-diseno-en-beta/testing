#!/usr/bin/env bash
# Crea UN donador. Los datos se pasan por argumento o el script te los pregunta.
#
# Uso:
#   ./crear-donador.sh
#       te pregunta cada campo, con valores por defecto entre corchetes
#
#   ./crear-donador.sh --nombre Carla --apellido Gomez --edad 29
#       lo que no pases lo pregunta
#
#   ./crear-donador.sh --nombre Carla --apellido Gomez --edad 29 \
#                      --email carla@test.com --documento 35333003 --domicilio "Mozart 2300"
#       no pregunta nada
#
#   ./crear-donador.sh --quejas 5
#       lo crea y le suma 5 quejas, para dejarlo SOSPECHOSO
#
#   ./crear-donador.sh --guardar-como DONADOR_DEMO
#       guarda el id en .estado con ese nombre, para usarlo en otros scripts
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

NOMBRE=""; APELLIDO=""; EDAD=""; EMAIL=""; DOCUMENTO=""; DOMICILIO=""
QUEJAS="0"; GUARDAR_COMO="DONADOR_OK"

while [ $# -gt 0 ]; do
  case "$1" in
    --nombre)        NOMBRE="$2"; shift 2 ;;
    --apellido)      APELLIDO="$2"; shift 2 ;;
    --edad)          EDAD="$2"; shift 2 ;;
    --email)         EMAIL="$2"; shift 2 ;;
    --documento)     DOCUMENTO="$2"; shift 2 ;;
    --domicilio)     DOMICILIO="$2"; shift 2 ;;
    --quejas)        QUEJAS="$2"; shift 2 ;;
    --guardar-como)  GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-donador.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UN DONADOR"

SUFIJO="$(date +%H%M%S)"
preguntar NOMBRE     "Nombre"                 "$PREFIJO-donador"
preguntar APELLIDO   "Apellido"               "Prueba"
preguntar EDAD       "Edad"                   "30"
preguntar EMAIL      "Email"                  "$PREFIJO-$SUFIJO@test.local"
preguntar DOCUMENTO  "Numero de documento"    "$SUFIJO"
preguntar DOMICILIO  "Domicilio"              "Calle de prueba 100"

echo "" >&2
detalle "nombre:    $NOMBRE $APELLIDO"
detalle "edad:      $EDAD"
detalle "email:     $EMAIL"
detalle "documento: $DOCUMENTO"
detalle "domicilio: $DOMICILIO"

paso "POST /donadores"
req POST "$URL_DONADORES/donadores" \
  "{\"nombre\":\"$NOMBRE\",\"apellido\":\"$APELLIDO\",\"edad\":$EDAD,\"email\":\"$EMAIL\",\"nroDocumento\":\"$DOCUMENTO\",\"domicilio\":\"$DOMICILIO\"}"

DONADOR=$(campo '.id')
creado "donador" "$DONADOR" || { resumen; exit 1; }
verificar "estado inicial" "VERIFICADO" "$(campo '.estado')"

# --- quejas opcionales, para dejarlo en un estado concreto ---
if [ "${QUEJAS:-0}" -gt 0 ] 2>/dev/null; then
  paso "Sumando $QUEJAS queja(s)"
  detalle "umbrales: 5 quejas -> SOSPECHOSO   |   10 quejas -> BANEADO"
  i=1
  while [ "$i" -le "$QUEJAS" ]; do
    curl -sS -m "$TIMEOUT" -o /dev/null -X POST -H 'Content-Type: application/json' \
      -d "{\"donacionID\":\"manual\",\"donadorID\":\"$DONADOR\",\"fecha\":\"$(date +%Y-%m-%d)\",\"descripcion\":\"queja manual $i\"}" \
      "$URL_DONADORES/donadores/$DONADOR/quejas"
    printf "." >&2
    i=$((i + 1))
  done
  echo "" >&2

  req GET "$URL_DONADORES/donadores/$DONADOR"
  ESTADO=$(campo '.estado')
  detalle "estado con $QUEJAS quejas: $ESTADO"
  if [ "$QUEJAS" -ge 10 ]; then
    verificar "con $QUEJAS quejas" "BANEADO" "$ESTADO"
  elif [ "$QUEJAS" -ge 5 ]; then
    verificar "con $QUEJAS quejas" "SOSPECHOSO" "$ESTADO"
  else
    verificar "con $QUEJAS quejas" "VERIFICADO" "$ESTADO"
  fi

  req GET "$URL_DONADORES/donadores/$DONADOR/puede-donar"
  detalle "puede-donar: $(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')"
  [ "$ESTADO" = "SOSPECHOSO" ] && detalle "(en SOSPECHOSO alterna: solo puede donar el 50% de las veces)"
fi

guardar "$GUARDAR_COMO" "$DONADOR"

echo "" >&2
echo "  Para usarlo:" >&2
echo "    ./donar.sh --donador $DONADOR" >&2
echo "    ./13-flujo-estadisticas.sh $DONADOR" >&2

# El id sale por stdout: se puede encadenar con  D=\$(./crear-donador.sh ...)
echo "$DONADOR"
resumen
