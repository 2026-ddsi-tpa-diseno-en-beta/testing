#!/usr/bin/env bash
# Mantiene despiertos los servicios de Render pegandoles cada 3 minutos.
#
# Render en free tier duerme un servicio despues de ~15 minutos sin trafico, y
# despertarlo tarda mas de 90 segundos. Durante una presentacion eso parece que el
# sistema no funciona.
#
# Dejalo corriendo en una terminal aparte ANTES de empezar y no la cierres.
#
# Uso:
#   ./keepalive.sh              cada 3 minutos (default)
#   ./keepalive.sh 120          cada 120 segundos
#   ./keepalive.sh 180 &        en segundo plano
#
# Para cortarlo: Ctrl+C, o kill del PID si lo mandaste al fondo.
set -u
. "$(dirname "$0")/lib/comun.sh"

INTERVALO="${1:-180}"

# En el keepalive no conviene esperar 200s: si un servicio no contesta en 60
# preferimos anotarlo y seguir con los demas.
TIMEOUT=60

titulo "KEEPALIVE DE LOS SERVICIOS DE RENDER"
echo "Intervalo: cada ${INTERVALO}s"
echo "Servicios:"
echo "  Donaciones  $URL_DONACIONES"
echo "  Donadores   $URL_DONADORES"
echo "  Incentivos  $URL_INCENTIVOS"
echo "  Logistica   $URL_LOGISTICA"
echo ""
echo "Dejalo corriendo. Cortar con Ctrl+C."
echo ""

RONDA=0
CAIDAS=0

# Un ping liviano. No usa la funcion req() para no llenar la pantalla de trazas.
ping_servicio() {
  local nombre="$1" url="$2" codigo inicio fin ms
  inicio=$(date +%s)
  codigo=$(curl -sS -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "$url/actuator/health" 2>/dev/null || echo "000")
  fin=$(date +%s)
  ms=$((fin - inicio))

  case "$codigo" in
    200)
      if [ "$ms" -gt 20 ]; then
        printf "  %-12s ${C_WARN}%s${C_OFF}  %ss  (estaba dormido, ya desperto)\n" "$nombre" "$codigo" "$ms"
      else
        printf "  %-12s ${C_OK}%s${C_OFF}  %ss\n" "$nombre" "$codigo" "$ms"
      fi
      ;;
    000)
      printf "  %-12s ${C_ERR}sin respuesta${C_OFF}  (timeout de ${TIMEOUT}s)\n" "$nombre"
      CAIDAS=$((CAIDAS + 1))
      ;;
    *)
      printf "  %-12s ${C_WARN}%s${C_OFF}  %ss\n" "$nombre" "$codigo" "$ms"
      ;;
  esac
}

# Ctrl+C corta con un resumen en vez de morir a la mitad.
terminar() {
  echo ""
  echo ""
  echo "${C_BOLD}Keepalive detenido.${C_OFF}"
  echo "  rondas completadas: $RONDA"
  echo "  servicios sin respuesta (acumulado): $CAIDAS"
  exit 0
}
trap terminar INT TERM

while true; do
  RONDA=$((RONDA + 1))
  echo "${C_DIM}[$(date '+%H:%M:%S')]${C_OFF} ronda $RONDA"
  ping_servicio "Donaciones" "$URL_DONACIONES"
  ping_servicio "Donadores"  "$URL_DONADORES"
  ping_servicio "Incentivos" "$URL_INCENTIVOS"
  ping_servicio "Logistica"  "$URL_LOGISTICA"
  sleep "$INTERVALO"
done
