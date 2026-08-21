#!/usr/bin/env bash
# Verifica que los 4 servicios respondan y los deja despiertos.
# Correr esto SIEMPRE primero: en Render free tier el primer request de cada
# servicio puede tardar mas de 90 segundos y hace fallar todo lo que venga despues.
set -u
. "$(dirname "$0")/lib/comun.sh"

titulo "SALUD DE LOS 4 SERVICIOS"
echo "Despertando los deploys. La primera vez puede tardar varios minutos."

chequear() {
  local nombre="$1" url="$2"
  paso "$nombre"
  detalle "$url"

  local inicio fin segundos
  inicio=$(date +%s)
  req GET "$url/actuator/health"
  fin=$(date +%s)
  segundos=$((fin - inicio))

  if [ "$HTTP_CODE" = "000" ]; then
    falla "$nombre no respondio en ${TIMEOUT}s"
    return
  fi

  local estado db
  estado=$(campo '.status')
  db=$(campo '.components.db.status')

  if [ "$estado" = "UP" ]; then
    ok "$nombre esta UP (${segundos}s)"
  else
    aviso "$nombre responde HTTP $HTTP_CODE con status='$estado' (${segundos}s)"
    detalle "si acaba de despertar, volve a correr este script"
  fi

  [ -n "$db" ] && detalle "base de datos: $db"

  if [ "$segundos" -gt 30 ]; then
    aviso "tardo ${segundos}s: estaba dormido. Ahora deberia responder rapido."
  fi
}

chequear "Donaciones" "$URL_DONACIONES"
chequear "Donadores y Entidades" "$URL_DONADORES"
chequear "Incentivos" "$URL_INCENTIVOS"
chequear "Logistica" "$URL_LOGISTICA"

chequear "Worker-1" "$URL_LOGISTICA_WORKER_1"
chequear "Worker-2" "$URL_LOGISTICA_WORKER_2"

paso "Modo de integracion de Donaciones"
req GET "$URL_DONACIONES/admin/estado"
if [ "$HTTP_CODE" = "200" ]; then
  reales=$(campo '.integracionesReales')
  if [ "$reales" = "true" ]; then
    ok "Donaciones apunta a los componentes reales"
  else
    falla "Donaciones tiene alguna integracion en modo LOCAL (fachada de prueba)"
    detalle "revisar las variables de entorno en Render"
  fi
else
  aviso "no se pudo leer /admin/estado (HTTP $HTTP_CODE)"
fi

resumen
