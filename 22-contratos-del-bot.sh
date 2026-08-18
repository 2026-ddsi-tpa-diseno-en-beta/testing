#!/usr/bin/env bash
# CONTRATOS QUE USA EL BOT DE TELEGRAM
#
# Que verifica:  que cada endpoint que el bot invoca exista y responda con el shape que el
#                bot espera, mandando exactamente los mismos bodies que manda el.
#
# Que NO verifica: el bot en si. El parseo de comandos, el gateo por rol y el formato de las
#                respuestas se prueban aparte, llamando a BotCommandHandler.handle() directo.
#                Este script sirve para saber si un cambio en Donadores y Entidades le va a
#                romper el bot, sin tener que levantarlo.
#
# Las 10 funcionalidades que pide la Entrega 4:
#   donador:  registrarse, consultar sus estadisticas, consultar donadores (por ID y todos)
#   admin:    crear entidad, editar entidad, consultar entidades (por ID y todas),
#             alta de necesidad, borrar necesidad, modificar necesidad, consultar necesidad
set -u
. "$(dirname "$0")/lib/comun.sh"

SELLO="$(date +%H%M%S)"
exigir_estado PRODUCTO

titulo "CONTRATOS QUE USA EL BOT DE TELEGRAM"
echo "Se mandan los mismos requests que hace el bot, contra Donadores y Entidades."

# ==================================================== rol donador
titulo "ROL DONADOR - 3 funcionalidades"

paso "1. /registrarse  ->  POST /donadores"
detalle 'body del bot: {nombre, apellido, edad, email, nroDocumento, domicilio}'
req POST "$URL_DONADORES/donadores" \
  "{\"nombre\":\"$PREFIJO-bot\",\"apellido\":\"Telegram\",\"edad\":28,\"email\":\"$PREFIJO-bot-$SELLO@test.local\",\"nroDocumento\":\"bot$SELLO\",\"domicilio\":\"Calle bot 100\"}"
DONADOR_BOT=$(campo '.id')
if [ -n "$DONADOR_BOT" ] && [ "$DONADOR_BOT" != "null" ]; then
  ok "el donador se registra y devuelve id: $DONADOR_BOT"
  verificar "el bot muestra el estado inicial" "VERIFICADO" "$(campo '.estado')"
else
  falla "no devolvio id (HTTP $HTTP_CODE): el comando /registrarse del bot va a fallar"
fi

paso "2. /estadisticas ID  ->  GET /donadores/{id}/estadisticas"
if [ -n "${DONADOR_BOT:-}" ] && [ "$DONADOR_BOT" != "null" ]; then
  req GET "$URL_DONADORES/donadores/$DONADOR_BOT/estadisticas"
  if [ "$HTTP_CODE" = "200" ]; then
    ok "responde 200"
    for c in estado categoria misionActualID insigniasID; do
      if printf '%s' "$HTTP_BODY" | grep -q "\"$c\""; then
        ok "trae el campo $c"
      else
        falla "falta el campo $c en la respuesta"
      fi
    done
  else
    falla "HTTP $HTTP_CODE"
  fi
else
  aviso "sin donador, se saltea"
fi

paso "3a. /donadores  ->  GET /donadores"
req GET "$URL_DONADORES/donadores"
if [ "$HTTP_CODE" = "200" ]; then
  ok "responde 200"
  LARGO=$(printf '%s' "$HTTP_BODY" | wc -c | tr -d ' ')
  detalle "tamanio de la respuesta: $LARGO caracteres"
  if [ "$LARGO" -gt 4096 ]; then
    falla "la respuesta supera los 4096 caracteres que permite Telegram"
    detalle "el bot manda el JSON crudo, asi que Telegram va a rechazar el mensaje"
    detalle "y el usuario no va a recibir nada. Hay que paginar o formatear."
  else
    RESTANTE=$((4096 - LARGO))
    ok "entra en un mensaje de Telegram (quedan $RESTANTE caracteres de margen)"
    POR_DONADOR=$(printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(len(sys.argv[1])/max(len(d),1)))
except Exception: print(0)
" "$HTTP_BODY" 2>/dev/null)
    if [ "${POR_DONADOR:-0}" -gt 0 ]; then
      TOPE=$((4096 / POR_DONADOR))
      detalle "a ~$POR_DONADOR caracteres por donador, el limite se alcanza con ~$TOPE donadores"
    fi
  fi
else
  falla "HTTP $HTTP_CODE"
fi

paso "3b. /donador_id ID  ->  GET /donadores/{id}"
if [ -n "${DONADOR_BOT:-}" ] && [ "$DONADOR_BOT" != "null" ]; then
  req GET "$URL_DONADORES/donadores/$DONADOR_BOT"
  verificar "responde 200" "200" "$HTTP_CODE"
fi

# ==================================================== rol admin
titulo "ROL ADMIN - 7 funcionalidades"

paso "4. /crear_entidad  ->  POST /entidades"
detalle 'body del bot: {razonSocial, domicilio, telefono, correo}'
req POST "$URL_DONADORES/entidades" \
  "{\"razonSocial\":\"$PREFIJO-Entidad-bot-$SELLO\",\"domicilio\":\"Av. bot 200\",\"telefono\":\"1140000001\",\"correo\":\"$PREFIJO-bot-$SELLO@entidad.test\"}"
ENTIDAD_BOT=$(campo '.id')
[ -n "$ENTIDAD_BOT" ] && [ "$ENTIDAD_BOT" != "null" ] \
  && ok "entidad creada: $ENTIDAD_BOT" \
  || falla "no devolvio id (HTTP $HTTP_CODE)"

paso "5. /editar_entidad  ->  PUT /entidades/{id}"
if [ -n "${ENTIDAD_BOT:-}" ] && [ "$ENTIDAD_BOT" != "null" ]; then
  NUEVO_DOM="Av. modificada 999"
  NUEVO_TEL="1149999999"
  req PUT "$URL_DONADORES/entidades/$ENTIDAD_BOT" \
    "{\"razonSocial\":\"$PREFIJO-Entidad-editada-$SELLO\",\"domicilio\":\"$NUEVO_DOM\",\"telefono\":\"$NUEVO_TEL\",\"correo\":\"$PREFIJO-bot-$SELLO@entidad.test\"}"
  if [ "$HTTP_CODE" = "200" ]; then
    ok "responde 200"
    # El bot manda los 4 campos: si el servidor aplica solo algunos, el admin cree que
    # edito y no edito. Hay que verificar campo por campo.
    req GET "$URL_DONADORES/entidades/$ENTIDAD_BOT"
    verificar "razonSocial se aplico" "$PREFIJO-Entidad-editada-$SELLO" "$(campo '.razonSocial')"
    verificar "domicilio se aplico"   "$NUEVO_DOM" "$(campo '.domicilio')"
    verificar "telefono se aplico"    "$NUEVO_TEL" "$(campo '.telefono')"
  else
    falla "HTTP $HTTP_CODE"
  fi
fi

paso "6a. /entidades  ->  GET /entidades"
req GET "$URL_DONADORES/entidades"
verificar "responde 200" "200" "$HTTP_CODE"

paso "6b. /entidad ID  ->  GET /entidades/{id}"
if [ -n "${ENTIDAD_BOT:-}" ] && [ "$ENTIDAD_BOT" != "null" ]; then
  req GET "$URL_DONADORES/entidades/$ENTIDAD_BOT"
  verificar "responde 200" "200" "$HTTP_CODE"
fi

paso "7. /alta_necesidad  ->  POST /necesidades"
detalle 'body del bot: {entidadID, productoSolicitadoID, descripcion, cantidadObjetivo, nivelDeUrgencia, tipo}'
if [ -n "${ENTIDAD_BOT:-}" ] && [ "$ENTIDAD_BOT" != "null" ]; then
  req POST "$URL_DONADORES/necesidades" \
    "{\"entidadID\":\"$ENTIDAD_BOT\",\"productoSolicitadoID\":\"$PRODUCTO\",\"descripcion\":\"$PREFIJO necesidad desde bot\",\"cantidadObjetivo\":20,\"nivelDeUrgencia\":6,\"tipo\":\"EXTRAORDINARIA\"}"
  NECESIDAD_BOT=$(campo '.id')
  [ -n "$NECESIDAD_BOT" ] && [ "$NECESIDAD_BOT" != "null" ] \
    && ok "necesidad creada: $NECESIDAD_BOT" \
    || falla "no devolvio id (HTTP $HTTP_CODE)"
fi

paso "8. /necesidad ID  ->  GET /necesidades/{id}"
if [ -n "${NECESIDAD_BOT:-}" ] && [ "$NECESIDAD_BOT" != "null" ]; then
  req GET "$URL_DONADORES/necesidades/$NECESIDAD_BOT"
  verificar "responde 200" "200" "$HTTP_CODE"
fi

paso "9. /modificar_necesidad  ->  PUT /necesidades/{id}"
if [ -n "${NECESIDAD_BOT:-}" ] && [ "$NECESIDAD_BOT" != "null" ]; then
  req PUT "$URL_DONADORES/necesidades/$NECESIDAD_BOT" \
    "{\"entidadID\":\"$ENTIDAD_BOT\",\"productoSolicitadoID\":\"$PRODUCTO\",\"descripcion\":\"$PREFIJO necesidad modificada\",\"cantidadObjetivo\":45,\"nivelDeUrgencia\":10,\"tipo\":\"EXTRAORDINARIA\"}"
  if [ "$HTTP_CODE" = "200" ]; then
    ok "responde 200"
    req GET "$URL_DONADORES/necesidades/$NECESIDAD_BOT"
    verificar "descripcion se aplico"     "$PREFIJO necesidad modificada" "$(campo '.descripcion')"
    verificar "cantidadObjetivo se aplico" "45" "$(campo '.cantidadObjetivo')"
    verificar "nivelDeUrgencia se aplico"  "10" "$(campo '.nivelDeUrgencia')"
  else
    falla "HTTP $HTTP_CODE"
  fi
fi

paso "10. /borrar_necesidad ID  ->  DELETE /necesidades/{id}"
if [ -n "${NECESIDAD_BOT:-}" ] && [ "$NECESIDAD_BOT" != "null" ]; then
  req DELETE "$URL_DONADORES/necesidades/$NECESIDAD_BOT"
  case "$HTTP_CODE" in
    200|204) ok "el borrado responde HTTP $HTTP_CODE" ;;
    *)       falla "HTTP $HTTP_CODE" ;;
  esac

  # El bot le muestra al usuario el body crudo de la respuesta. Si viene vacio, Telegram
  # rechaza un sendMessage con texto vacio y el admin no ve NADA aunque el borrado funcione.
  if [ -z "$HTTP_BODY" ]; then
    falla "la respuesta viene con body vacio"
    detalle "el bot pasa el body crudo a Telegram, y un mensaje vacio se rechaza:"
    detalle "el admin borra la necesidad, se borra bien, y no ve ninguna confirmacion"
    detalle "el bot tendria que mandar un texto fijo cuando el body viene vacio"
  else
    ok "la respuesta trae body, el bot tiene algo que mostrar"
  fi

  req GET "$URL_DONADORES/necesidades/$NECESIDAD_BOT"
  case "$HTTP_CODE" in
    404) ok "la necesidad ya no existe: el borrado surtio efecto" ;;
    200) falla "la necesidad sigue existiendo despues del DELETE" ;;
    *)   aviso "al buscarla despues del borrado responde HTTP $HTTP_CODE" ;;
  esac
fi

resumen
