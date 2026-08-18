#!/usr/bin/env bash
# FLUJO 5 - REGISTRAR UNA QUEJA Y PROBAR EL BANEO
#
# Una entidad se queja de una donacion ACEPTADA. Donaciones registra la queja en
# Donadores y Entidades y pasa la donacion a CONQUEJA.
#
# Umbrales del enunciado:  5 quejas -> SOSPECHOSO   |   10 quejas -> BANEADO
#
# Uso:  ./14-flujo-queja-baneo.sh              solo la queja sobre la ultima donacion
#       ./14-flujo-queja-baneo.sh umbrales     recorre las 10 quejas de un donador nuevo
set -u
. "$(dirname "$0")/lib/comun.sh"

MODO="${1:-queja}"

titulo "FLUJO 5 - QUEJA Y BANEO"

# ============================================================ parte A
if [ "$MODO" = "queja" ]; then
  exigir_estado DONACION

  echo "donacion: $DONACION"
  paso "1. La donacion tiene que estar ACEPTADA para poder recibir una queja"
  req GET "$URL_DONACIONES/donaciones/$DONACION"
  ESTADO=$(campo '.estado')
  DONADOR_DE_LA_DONACION=$(campo '.donadorID')
  detalle "estado actual: $ESTADO"

  if [ "$ESTADO" != "ACEPTADA" ]; then
    aviso "la donacion esta en $ESTADO, no en ACEPTADA"
    detalle "corre primero ./11-flujo-reportar-entrega.sh"
    detalle "el enunciado solo permite quejarse de una donacion aceptada"
    resumen; exit 0
  fi
  ok "la donacion esta ACEPTADA"

  paso "2. Quejas del donador antes"
  req GET "$URL_DONADORES/donadores/$DONADOR_DE_LA_DONACION/quejas"
  ANTES=$(printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)
" 2>/dev/null)
  detalle "quejas: ${ANTES:-0}"

  paso "3. Registrar la queja en Donaciones"
  req POST "$URL_DONACIONES/donaciones/$DONACION/quejas" \
    '{"descripcion":"los productos llegaron en mal estado"}'
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    ok "queja registrada"
    verificar "la donacion pasa a CONQUEJA" "CONQUEJA" "$(campo '.estado')"
  else
    falla "no se pudo registrar la queja (HTTP $HTTP_CODE)"
  fi

  paso "4. La queja tiene que haber llegado a Donadores y Entidades"
  req GET "$URL_DONADORES/donadores/$DONADOR_DE_LA_DONACION/quejas"
  DESPUES=$(printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)
" 2>/dev/null)
  detalle "quejas: ${DESPUES:-0} (antes: ${ANTES:-0})"
  if [ "${DESPUES:-0}" -gt "${ANTES:-0}" ]; then
    ok "Donaciones propago la queja correctamente"
  else
    falla "la queja no aparece en Donadores y Entidades"
  fi

  paso "5. Trazabilidad de la donacion"
  req GET "$URL_DONACIONES/donaciones/$DONACION/historial"
  detalle "$(printf '%s' "$HTTP_BODY" | head -c 400)"

  echo ""
  echo "Para ver los umbrales de estado:  ./14-flujo-queja-baneo.sh umbrales"
  resumen
  exit $?
fi

# ============================================================ parte B
titulo "UMBRALES DE ESTADO DEL DONADOR"
echo "Se crea un donador nuevo y se le suman 10 quejas de a una."
echo "Esperado:  1-4 VERIFICADO   |   5-9 SOSPECHOSO   |   10 BANEADO"

req POST "$URL_DONADORES/donadores" \
  "{\"nombre\":\"$PREFIJO-umbrales\",\"apellido\":\"Prueba\",\"edad\":30,\"email\":\"$PREFIJO-umb-$(date +%s)@test.local\",\"nroDocumento\":\"$(date +%s)\",\"domicilio\":\"Calle umbral 1\"}"
D=$(campo '.id')
if [ -z "$D" ] || [ "$D" = "null" ]; then
  falla "no se pudo crear el donador de prueba"; resumen; exit 1
fi
detalle "donador: $D"

paso "Estado inicial"
req GET "$URL_DONADORES/donadores/$D"
verificar "arranca en VERIFICADO" "VERIFICADO" "$(campo '.estado')"

echo ""
printf "  %-7s %-13s %s\n" "QUEJA" "ESTADO" "PUEDE-DONAR"
printf "  %-7s %-13s %s\n" "-----" "------" "-----------"

i=1
while [ "$i" -le 10 ]; do
  curl -sS -m "$TIMEOUT" -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d "{\"donacionID\":\"umbral\",\"donadorID\":\"$D\",\"fecha\":\"$(date +%Y-%m-%d)\",\"descripcion\":\"queja $i\"}" \
    "$URL_DONADORES/donadores/$D/quejas"

  EST=$(curl -sS -m "$TIMEOUT" "$URL_DONADORES/donadores/$D" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('estado'))
except Exception: print('?')
" 2>/dev/null)
  PD=$(curl -sS -m "$TIMEOUT" "$URL_DONADORES/donadores/$D/puede-donar" | tr -d '[:space:]')

  printf "  %-7s %-13s %s\n" "$i" "$EST" "$PD"

  if [ "$i" -eq 4 ]; then
    [ "$EST" = "VERIFICADO" ] && ok "con 4 quejas sigue VERIFICADO" || falla "con 4 quejas deberia ser VERIFICADO, es $EST"
  fi
  if [ "$i" -eq 5 ]; then
    [ "$EST" = "SOSPECHOSO" ] && ok "a las 5 quejas paso a SOSPECHOSO" || falla "a las 5 quejas deberia ser SOSPECHOSO, es $EST"
  fi
  if [ "$i" -eq 10 ]; then
    [ "$EST" = "BANEADO" ] && ok "a las 10 quejas paso a BANEADO" || falla "a las 10 quejas deberia ser BANEADO, es $EST"
    [ "$PD" = "false" ] && ok "un donador baneado no puede donar" || falla "un baneado no deberia poder donar, puede-donar=$PD"
  fi
  i=$((i + 1))
done

echo ""
detalle "entre la queja 5 y la 9 el puede-donar tiene que alternar: un SOSPECHOSO"
detalle "solo puede donar el 50% de las veces, de forma aleatoria"

resumen
