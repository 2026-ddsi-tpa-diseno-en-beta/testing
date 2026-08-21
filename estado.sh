#!/usr/bin/env bash
# Muestra el estado actual de todo el sistema de un vistazo.
#
# No crea ni modifica nada: son todos GET. Sirve para saber donde estas parado antes de
# empezar a probar, y para mostrarle a alguien como esta el sistema ahora mismo.
#
# Uso:  ./estado.sh              resumen
#       ./estado.sh --detalle    ademas lista las entidades una por una
#       ./estado.sh --ids        solo los IDs guardados en .estado
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

DETALLE="no"
[ "${1:-}" = "--detalle" ] && DETALLE="si"

# --- solo los IDs guardados ---
if [ "${1:-}" = "--ids" ]; then
  titulo "IDS GUARDADOS EN .estado"
  if [ -f "$ARCHIVO_ESTADO" ]; then
    sed 's/^/  /' "$ARCHIVO_ESTADO" >&2
  else
    echo "  (vacio: corre ./01-seed.sh o los scripts crear-*.sh)" >&2
  fi
  exit 0
fi

# Cuenta los elementos de un array JSON.
contar() {
  printf '%s' "$1" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 1)
except Exception: print(0)
" 2>/dev/null
}

# Lista los primeros N elementos mostrando los campos que se le pasen.
listar() {
  local cuantos="$1"; shift
  printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
campos=sys.argv[2:]
try: d=json.load(sys.stdin)
except Exception: sys.exit()
if not isinstance(d,list): d=[d]
for x in d[:int(sys.argv[1])]:
    print('      ' + '  |  '.join(str(x.get(c,'-'))[:34] for c in campos))
if len(d) > int(sys.argv[1]):
    print('      ... y ' + str(len(d)-int(sys.argv[1])) + ' mas')
" "$cuantos" "$@" >&2 2>/dev/null
}

titulo "ESTADO ACTUAL DEL SISTEMA"
echo "  $(date '+%Y-%m-%d %H:%M:%S')" >&2

# ============================================================ disponibilidad
titulo "DISPONIBILIDAD"
detalle "si algun servicio esta dormido, despertarlo puede tardar mas de 90s"
for par in "Donaciones|$URL_DONACIONES" "Donadores|$URL_DONADORES" \
           "Incentivos|$URL_INCENTIVOS" "Logistica|$URL_LOGISTICA" \
           "Worker-1|$URL_LOGISTICA_WORKER_1" "Worker-2|$URL_LOGISTICA_WORKER_2"; do
  nombre="${par%%|*}"; url="${par##*|}"
  inicio=$(date +%s)
  # curl con -w siempre imprime un codigo (000 si fallo), asi que no hace falta un || echo:
  # ponerlo duplicaba la salida y mostraba "000000".
  codigo=$(curl -sS -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "$url/actuator/health" 2>/dev/null)
  [ -z "$codigo" ] && codigo="000"
  fin=$(date +%s)
  segundos=$((fin - inicio))
  case "$codigo" in
    200) if [ "$segundos" -gt 20 ]; then
           printf "  %-12s ${C_OK}UP${C_OFF}  %ss  (estaba dormido)\n" "$nombre" "$segundos" >&2
         else
           printf "  %-12s ${C_OK}UP${C_OFF}  %ss\n" "$nombre" "$segundos" >&2
         fi ;;
    000) printf "  %-12s ${C_ERR}sin respuesta${C_OFF}  (timeout de ${TIMEOUT}s)\n" "$nombre" >&2 ;;
    *)   printf "  %-12s ${C_WARN}HTTP %s${C_OFF}  %ss\n" "$nombre" "$codigo" "$segundos" >&2 ;;
  esac
done

# ============================================================ donaciones
titulo "DONACIONES"
req GET "$URL_DONACIONES/admin/estado" >/dev/null 2>&1
if [ "$HTTP_CODE" = "200" ]; then
  printf "  donaciones: %-6s productos: %-6s categorias: %-6s identificadores: %s\n" \
    "$(campo '.donaciones')" "$(campo '.productos')" \
    "$(campo '.categorias')" "$(campo '.identificadores')" >&2
  printf "  integraciones reales: %s\n" "$(campo '.integracionesReales')" >&2
  printf "    donadores: %s\n" "$(campo '.integraciones.donadoresYEntidades')" >&2
  printf "    logistica: %s\n" "$(campo '.integraciones.logistica')" >&2
else
  aviso "no se pudo leer /admin/estado (HTTP $HTTP_CODE)"
fi

if [ "$DETALLE" = "si" ]; then
  paso "Ultimas donaciones"
  req GET "$URL_DONACIONES/donaciones" >/dev/null 2>&1
  detalle "id | donador | producto | cantidad | estado"
  listar 8 id donadorID productoID cantidad estado

  paso "Productos"
  req GET "$URL_DONACIONES/productos" >/dev/null 2>&1
  detalle "id | nombre | categoria | identificador"
  listar 8 id nombre categoriaID identificadorID

  paso "Categorias"
  req GET "$URL_DONACIONES/categorias" >/dev/null 2>&1
  detalle "id | nombre | padre | es subcategoria"
  listar 10 id nombre categoriaPadreID esSubcategoria
fi

# ============================================================ donadores
titulo "DONADORES Y ENTIDADES"
req GET "$URL_DONADORES/donadores" >/dev/null 2>&1
if [ "$HTTP_CODE" = "200" ] && [ -n "$HTTP_BODY" ]; then
  # Cuenta cuantos hay en cada estado, para ver de un vistazo si hay baneados o sospechosos.
  printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
from collections import Counter
try: d=json.load(sys.stdin)
except Exception:
    print('  donadores: no se pudo interpretar la respuesta'); sys.exit()
c=Counter((x.get('estado') or 'sin estado') for x in d)
print('  donadores: ' + str(len(d)) + '   ' + '   '.join(k + ': ' + str(v) for k,v in sorted(c.items())))
" >&2 2>/dev/null
else
  aviso "no se pudo leer los donadores (HTTP $HTTP_CODE)"
fi

if [ "$DETALLE" = "si" ]; then
  detalle "id | nombre | estado | categoria"
  listar 8 id nombre estado categoria
fi

req GET "$URL_DONADORES/entidades" >/dev/null 2>&1
printf "  entidades: %s\n" "$(contar "$HTTP_BODY")" >&2
if [ "$DETALLE" = "si" ]; then
  detalle "id | razon social | domicilio"
  listar 8 id razonSocial domicilio
fi

if [ -n "${PRODUCTO:-}" ]; then
  req GET "$URL_DONADORES/necesidades?productoSolicitadoID=$PRODUCTO" >/dev/null 2>&1
  printf "  necesidades insatisfechas del producto %s: %s\n" "$PRODUCTO" "$(contar "$HTTP_BODY")" >&2
  if [ "$DETALLE" = "si" ]; then
    detalle "id | tipo | objetivo | urgencia"
    listar 8 id tipo cantidadObjetivo nivelDeUrgencia
  fi
fi

# ============================================================ logistica
titulo "LOGISTICA"
req GET "$URL_LOGISTICA/admin/db/status" >/dev/null 2>&1
if [ "$HTTP_CODE" = "200" ]; then
  printf "  depositos: %-6s paquetes: %-6s asignaciones: %s\n" \
    "$(campo '.depositos')" "$(campo '.paquetes')" "$(campo '.asignaciones')" >&2
else
  aviso "no se pudo leer /admin/db/status (HTTP $HTTP_CODE)"
fi

paso "Estado de la cola de matchmaking"
METRICAS=$(curl -sS -m 60 "$URL_LOGISTICA/actuator/prometheus" 2>/dev/null)
leer() { printf '%s' "$METRICAS" | grep "^$1" | head -1 | awk '{print $2}' | cut -d. -f1; }
PUB=$(leer "rabbitmq_published_total"); CONS=$(leer "rabbitmq_consumed_total")
REJ=$(leer "rabbitmq_rejected_total")
LIS=$(printf '%s' "$METRICAS" | grep -c "spring_rabbitmq_listener")
printf "  publicados: %-5s consumidos: %-5s rechazados: %-5s listeners en la API: %s\n" \
  "${PUB:-?}" "${CONS:-?}" "${REJ:-?}" "${LIS:-0}" >&2

if [ "${PUB:-0}" != "0" ] && [ "${CONS:-0}" = "0" ]; then
  aviso "hay mensajes publicados que nadie consumio: no hay Worker escuchando"
elif [ "${REJ:-0}" != "0" ] && [ "${REJ:-0}" != "?" ]; then
  aviso "hay mensajes rechazados: el Worker esta fallando al procesarlos"
elif [ "${CONS:-0}" != "0" ]; then
  ok "la cola se esta consumiendo"
fi

if [ "$DETALLE" = "si" ]; then
  paso "Depositos"
  req GET "$URL_LOGISTICA/depositos" >/dev/null 2>&1
  detalle "id | nombre | capacidad | algoritmo"
  listar 8 id nombre capacidadMaxima algoritmo
fi

# ============================================================ incentivos
titulo "INCENTIVOS"
req GET "$URL_INCENTIVOS/insignias" >/dev/null 2>&1
printf "  insignias: %s\n" "$(contar "$HTTP_BODY")" >&2
if [ "$DETALLE" = "si" ]; then
  detalle "id | nombre"
  listar 8 id nombre
fi

req GET "$URL_INCENTIVOS/misiones" >/dev/null 2>&1
printf "  misiones: %s\n" "$(contar "$HTTP_BODY")" >&2
if [ "$DETALLE" = "si" ]; then
  detalle "id | nombre | tipo | desde | hasta"
  listar 8 id nombre tipo categoriaInicio categoriaFin
fi

req GET "$URL_INCENTIVOS/actuator/metrics/donatrack.incentivos.cron.ejecuciones" >/dev/null 2>&1
if [ "$HTTP_CODE" = "200" ]; then
  printf "  ejecuciones del cron: %s\n" "$(campo '.measurements[0].value')" >&2
fi

# ============================================================ ids
titulo "IDS DE LA ULTIMA CORRIDA"
if [ -f "$ARCHIVO_ESTADO" ]; then
  sed 's/^/  /' "$ARCHIVO_ESTADO" >&2
else
  echo "  (vacio)" >&2
fi

echo "" >&2
echo "  Para ver el detalle:  ./estado.sh --detalle" >&2
