#!/usr/bin/env bash
# Crea UN deposito y le setea el algoritmo de matchmaking.
#
# El enunciado pide que el algoritmo arranque en null al crear el deposito y se setee despues
# por la fachada. El script verifica las dos cosas.
#
# Algoritmos:
#   SUB_ATENDIDOS        elige la necesidad mas alejada de cumplir su cantidad objetivo
#   PRIORIDAD_POR_SCORE  score = urgencia / (cantidad_producto / cantidad_objetivo)
#
# Uso:
#   ./crear-deposito.sh
#   ./crear-deposito.sh --nombre "Deposito Central" --capacidad 1000
#   ./crear-deposito.sh --nombre "Deposito Score" --capacidad 500 --algoritmo PRIORIDAD_POR_SCORE
#   ./crear-deposito.sh --nombre "Sin algoritmo" --algoritmo ninguno
#       lo deja en null, para mostrar que gestionarDonacion falla sin algoritmo seteado
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

NOMBRE=""; DIRECCION=""; CAPACIDAD=""; ALGORITMO=""; GUARDAR_COMO="DEPOSITO"

while [ $# -gt 0 ]; do
  case "$1" in
    --nombre)        NOMBRE="$2"; shift 2 ;;
    --direccion)     DIRECCION="$2"; shift 2 ;;
    --capacidad)     CAPACIDAD="$2"; shift 2 ;;
    --algoritmo)     ALGORITMO="$2"; shift 2 ;;
    --guardar-como)  GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-deposito.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UN DEPOSITO"

preguntar NOMBRE    "Nombre del deposito"                                  "$PREFIJO-Deposito-$(date +%H%M%S)"
preguntar DIRECCION "Direccion"                                            "Av. de prueba 3000"
preguntar CAPACIDAD "Capacidad maxima en unidades"                          "1000"
preguntar ALGORITMO "Algoritmo (SUB_ATENDIDOS / PRIORIDAD_POR_SCORE / ninguno)" "SUB_ATENDIDOS"

detalle "cada unidad de cualquier producto ocupa 1 lugar de la capacidad"

paso "POST /depositos"
req POST "$URL_LOGISTICA/depositos" \
  "{\"nombre\":\"$NOMBRE\",\"direccion\":\"$DIRECCION\",\"capacidadMaxima\":$CAPACIDAD}"

DEPOSITO_NUEVO=$(campo '.id')
creado "deposito" "$DEPOSITO_NUEVO" || { resumen; exit 1; }

paso "El algoritmo tiene que arrancar en null"
req GET "$URL_LOGISTICA/depositos/$DEPOSITO_NUEVO"
verificar "algoritmo al crear" "null" "$(campo '.algoritmo')"

if [ "$ALGORITMO" = "ninguno" ] || [ -z "$ALGORITMO" ]; then
  aviso "se deja sin algoritmo"
  detalle "gestionarDonacion deberia fallar hasta que se le setee uno"
else
  paso "Seteando el algoritmo $ALGORITMO"
  req PATCH "$URL_LOGISTICA/depositos/$DEPOSITO_NUEVO/algoritmo" "{\"algoritmo\":\"$ALGORITMO\"}"
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO_NUEVO"
  verificar "algoritmo seteado" "$ALGORITMO" "$(campo '.algoritmo')"
fi

guardar "$GUARDAR_COMO" "$DEPOSITO_NUEVO"

echo "" >&2
echo "  Para donar a este deposito:" >&2
echo "    ./donar.sh --deposito $DEPOSITO_NUEVO --cantidad 40" >&2
echo "" >&2
echo "  Para comparar los dos algoritmos, crea otro con el otro y donale lo mismo:" >&2
echo "    ./crear-deposito.sh --algoritmo PRIORIDAD_POR_SCORE --guardar-como DEPOSITO_SCORE" >&2

echo "$DEPOSITO_NUEVO"
resumen
