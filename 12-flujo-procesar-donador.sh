#!/usr/bin/env bash
# FLUJO 3 - PROCESAR AL DONADOR (Incentivos)
#
# Incentivos evalua las misiones asignadas leyendo el historial de donaciones del donador,
# y al completar una le otorga la insignia y lo sube de categoria.
#
# Ademas verifica dos cosas que ya rompieron antes:
#   - que el progreso sea POR DONADOR y no global (asigna la misma mision a dos donadores,
#     procesa uno solo y controla que el otro no se vea afectado)
#   - que el cron este ejecutando
set -u
. "$(dirname "$0")/lib/comun.sh"

exigir_estado MISION
exigir_estado DONADOR_OK

titulo "FLUJO 3 - PROCESAR AL DONADOR"
echo "mision:   $MISION"
echo "donador:  $DONADOR_OK"

req GET "$URL_INCENTIVOS/misiones/$MISION"
MISION_JSON="$HTTP_BODY"
if [ "$HTTP_CODE" != "200" ]; then
  falla "no se pudo leer la mision $MISION (HTTP $HTTP_CODE)"
  resumen; exit 1
fi

# ------------------------------------------------------------------ asignar
paso "1. Asignar la mision al donador"
req POST "$URL_INCENTIVOS/misiones/donador/$DONADOR_OK" "$MISION_JSON"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "201" ]; then
  ok "mision asignada"
else
  falla "no se pudo asignar la mision (HTTP $HTTP_CODE)"
  resumen; exit 1
fi

paso "2. La mision tiene que aparecer como en curso"
req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR_OK"
if [ "$HTTP_CODE" = "200" ] && [ -n "$HTTP_BODY" ]; then
  ok "mision en curso: $(campo '.nombre')"
else
  falla "no devuelve la mision en curso (HTTP $HTTP_CODE)"
fi

# ------------------------------------------------- progreso por donador
paso "3. Control: el progreso tiene que ser POR DONADOR, no global"
detalle "se asigna la misma mision a un segundo donador y se procesa solo al primero"

DONADOR_CONTROL=""
req POST "$URL_DONADORES/donadores" \
  "{\"nombre\":\"$PREFIJO-control\",\"apellido\":\"Prueba\",\"edad\":25,\"email\":\"$PREFIJO-control-$(date +%s)@test.local\",\"nroDocumento\":\"$(date +%s)\",\"domicilio\":\"Calle control 1\"}"
DONADOR_CONTROL=$(campo '.id')

if [ -n "$DONADOR_CONTROL" ] && [ "$DONADOR_CONTROL" != "null" ]; then
  detalle "donador de control: $DONADOR_CONTROL"
  req POST "$URL_INCENTIVOS/misiones/donador/$DONADOR_CONTROL" "$MISION_JSON"

  req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR_CONTROL"
  CONTROL_ANTES="$HTTP_CODE"
  detalle "el control tiene mision en curso (HTTP $CONTROL_ANTES)"

  paso "4. Procesar SOLO al primer donador"
  req POST "$URL_INCENTIVOS/procesamiento/$DONADOR_OK"
  detalle "HTTP $HTTP_CODE"

  paso "5. El donador de control no tiene que haberse visto afectado"
  req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR_CONTROL"
  if [ "$HTTP_CODE" = "$CONTROL_ANTES" ] && [ -n "$HTTP_BODY" ]; then
    ok "el control conserva su mision: el progreso es por donador"
  else
    falla "el control cambio de estado sin haber sido procesado (HTTP $CONTROL_ANTES -> $HTTP_CODE)"
    detalle "sintoma de progreso compartido entre donadores"
  fi
else
  aviso "no se pudo crear el donador de control, se saltea la verificacion"
  paso "4. Procesar al donador"
  req POST "$URL_INCENTIVOS/procesamiento/$DONADOR_OK"
fi

# ------------------------------------------------------------------ resultado
paso "6. Resultado para el donador procesado"
req GET "$URL_INCENTIVOS/insignias/donador/$DONADOR_OK"
detalle "insignias: $(printf '%s' "$HTTP_BODY" | head -c 200)"

req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR_OK"
detalle "mision en curso ahora: HTTP $HTTP_CODE"
detalle "la mision COMPLETITUD necesita donaciones en 3 categorias distintas"
detalle "con una sola categoria cargada es esperable que siga en curso"

# ------------------------------------------------------------------ cron
paso "7. El cron de Incentivos"
req GET "$URL_INCENTIVOS/actuator/metrics/donatrack.incentivos.cron.ejecuciones"
if [ "$HTTP_CODE" = "200" ]; then
  EJEC=$(campo '.measurements[0].value')
  detalle "ejecuciones acumuladas: $EJEC"
  case "$EJEC" in
    0|0.0|"") aviso "el contador esta en 0 en esta instancia"
              detalle "Render puede tener varias instancias y el contador que se lee"
              detalle "no es necesariamente el de la que corre el cron."
              detalle "Para confirmarlo hay que mirar los logs del servicio en Render." ;;
    *)        ok "el cron ejecuto $EJEC veces" ;;
  esac
else
  aviso "no se pudo leer la metrica del cron (HTTP $HTTP_CODE)"
fi

resumen
