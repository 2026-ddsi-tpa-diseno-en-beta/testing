#!/usr/bin/env bash
# Borra TODOS los datos de los cuatro modulos usando los endpoints de admin.
#
# OJO: no borra solo lo que crearon estos scripts. Vacia las bases completas,
# incluyendo lo que hayan cargado a mano para una demo. Pide confirmacion.
set -u
. "$(dirname "$0")/lib/comun.sh"

titulo "LIMPIAR LAS BASES DE LOS 4 MODULOS"
echo "${C_ERR}Esto borra TODO, no solo los datos de prueba.${C_OFF}"
echo ""
echo "Se van a llamar:"
echo "  DELETE $URL_DONACIONES/admin/datos"
echo "  DELETE $URL_DONADORES/sistema/base-de-datos"
echo "  DELETE $URL_INCENTIVOS/admin/datos"
echo "  DELETE $URL_LOGISTICA/admin/db"
echo ""

if [ "${1:-}" != "--si" ]; then
  printf "Escribi BORRAR para confirmar: "
  read -r respuesta
  if [ "$respuesta" != "BORRAR" ]; then
    echo "Cancelado."
    exit 0
  fi
fi

borrar() {
  paso "$1"
  req DELETE "$2"
  case "$HTTP_CODE" in
    200|204) ok "$1 limpiado" ;;
    *)       aviso "$1 respondio HTTP $HTTP_CODE" ;;
  esac
}

borrar "Donaciones"            "$URL_DONACIONES/admin/datos"
borrar "Donadores y Entidades" "$URL_DONADORES/sistema/base-de-datos"
borrar "Incentivos"            "$URL_INCENTIVOS/admin/datos"
borrar "Logistica"             "$URL_LOGISTICA/admin/db"

paso "Borrando el estado local"
rm -f "$ARCHIVO_ESTADO"
ok "archivo .estado eliminado"

echo ""
echo "Para volver a dejar todo listo:  ./01-seed.sh"
resumen
