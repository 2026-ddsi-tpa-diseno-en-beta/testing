#!/usr/bin/env bash
# Ejecuta el guion completo en orden y deja un resumen final por flujo.
# Cada script imprime todo su detalle, asi que la salida es larga a proposito.
#
# Uso:  ./correr-todo.sh                    todo
#       ./correr-todo.sh | tee corrida.log  todo, guardando la salida
set -u
cd "$(dirname "$0")"
. lib/comun.sh

RESULTADOS=""

correr() {
  local script="$1" etiqueta="$2"
  echo ""
  echo "${C_BOLD}##############################################################${C_OFF}"
  echo "${C_BOLD}#  $etiqueta${C_OFF}"
  echo "${C_BOLD}#  $script${C_OFF}"
  echo "${C_BOLD}##############################################################${C_OFF}"

  if "./$script"; then
    RESULTADOS="$RESULTADOS
  ${C_OK}[PASO]${C_OFF}  $etiqueta"
  else
    RESULTADOS="$RESULTADOS
  ${C_ERR}[FALLO]${C_OFF} $etiqueta"
  fi
}

echo "${C_BOLD}DonaTrack - guion completo de pruebas${C_OFF}"
echo "Arranca: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Servicios:"
echo "  Donaciones  $URL_DONACIONES"
echo "  Donadores   $URL_DONADORES"
echo "  Incentivos  $URL_INCENTIVOS"
echo "  Logistica   $URL_LOGISTICA"

correr "00-salud.sh"                      "Salud de los 4 servicios"
correr "01-seed.sh"                       "Carga de precondiciones"
correr "10-flujo-registrar-donacion.sh"   "Flujo 1 - Registrar una donacion"
correr "11-flujo-reportar-entrega.sh"     "Flujo 2 - Reportar una entrega"
correr "12-flujo-procesar-donador.sh"     "Flujo 3 - Procesar al donador"
correr "13-flujo-estadisticas.sh"         "Flujo 4 - Estadisticas de un donador"
correr "14-flujo-queja-baneo.sh"          "Flujo 5 - Queja y baneo"
correr "20-flujo-necesidad-y-stock.sh"    "E4 - Necesidad contra stock y asignacion inmediata"
correr "21-flujo-parcialidad-por-tipo.sh" "E4 - Parcialidad segun tipo de necesidad"
correr "22-contratos-del-bot.sh"          "E4 - Contratos que usa el bot de Telegram"

echo ""
echo "${C_BOLD}==============================================================${C_OFF}"
echo "${C_BOLD}  RESUMEN FINAL${C_OFF}"
echo "${C_BOLD}==============================================================${C_OFF}"
printf '%b\n' "$RESULTADOS"
echo ""
echo "Termina: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "El detalle de cada paso esta mas arriba. Para revisarlo con calma:"
echo "  ./correr-todo.sh | tee corrida.log"

printf '%b' "$RESULTADOS" | grep -q "FALLO" && exit 1 || exit 0
