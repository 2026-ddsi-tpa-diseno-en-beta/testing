#!/usr/bin/env bash
# Funciones compartidas por todos los scripts. No se ejecuta solo: se hace source.
# Compatible con bash 3.2 (el que trae macOS), asi que sin arrays asociativos.

# ------------------------------------------------------------------ colores
if [ -t 2 ]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_INFO=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''; C_BOLD=''; C_DIM=''; C_OFF=''
fi

# ------------------------------------------------------------------ contadores
TOTAL_OK=0
TOTAL_FALLA=0
TOTAL_AVISO=0

# Importante: todo el logueo sale por stderr, no por stdout. Asi las funciones que
# devuelven un valor se pueden usar con $(...) sin que se mezcle la traza.
titulo() {
  {
    echo ""
    echo "${C_BOLD}==============================================================${C_OFF}"
    echo "${C_BOLD} $1${C_OFF}"
    echo "${C_BOLD}==============================================================${C_OFF}"
  } >&2
}

paso() { { echo ""; echo "${C_INFO}--> $1${C_OFF}"; } >&2; }

ok() {
  TOTAL_OK=$((TOTAL_OK + 1))
  echo "    ${C_OK}[OK]${C_OFF} $1" >&2
}

falla() {
  TOTAL_FALLA=$((TOTAL_FALLA + 1))
  echo "    ${C_ERR}[FALLA]${C_OFF} $1" >&2
}

aviso() {
  TOTAL_AVISO=$((TOTAL_AVISO + 1))
  echo "    ${C_WARN}[AVISO]${C_OFF} $1" >&2
}

detalle() { echo "    ${C_DIM}$1${C_OFF}" >&2; }

# Compara lo esperado con lo obtenido y reporta.
verificar() {
  local descripcion="$1" esperado="$2" obtenido="$3"
  if [ "$esperado" = "$obtenido" ]; then
    ok "$descripcion  (= $obtenido)"
  else
    falla "$descripcion  esperado: $esperado  |  obtenido: $obtenido"
  fi
}

resumen() {
  {
    echo ""
    echo "${C_BOLD}--------------------------------------------------------------${C_OFF}"
    printf "  %sOK: %d%s   %sFALLAS: %d%s   %sAVISOS: %d%s\n" \
      "$C_OK" "$TOTAL_OK" "$C_OFF" "$C_ERR" "$TOTAL_FALLA" "$C_OFF" \
      "$C_WARN" "$TOTAL_AVISO" "$C_OFF"
    echo "${C_BOLD}--------------------------------------------------------------${C_OFF}"
  } >&2
  [ "$TOTAL_FALLA" -eq 0 ]
}

# ------------------------------------------------------------------ HTTP
# Timeout generoso: Render en free tier tarda mas de 90s en despertar.
TIMEOUT="${TIMEOUT:-200}"

# req METODO URL [BODY]  ->  deja el resultado en HTTP_CODE y HTTP_BODY
req() {
  local metodo="$1" url="$2" body="${3:-}" bruto
  if [ -n "$body" ]; then
    bruto=$(curl -sS -m "$TIMEOUT" -w $'\n<<%{http_code}>>' \
      -X "$metodo" -H 'Content-Type: application/json' -d "$body" "$url" 2>&1)
  else
    bruto=$(curl -sS -m "$TIMEOUT" -w $'\n<<%{http_code}>>' -X "$metodo" "$url" 2>&1)
  fi
  HTTP_CODE=$(printf '%s' "$bruto" | tail -1 | sed 's/.*<<//; s/>>.*//')
  HTTP_BODY=$(printf '%s' "$bruto" | sed '$d')
  case "$HTTP_CODE" in
    ''|*[!0-9]*) HTTP_CODE="000" ;;
  esac
  detalle "$metodo ${url#http*//*/} -> HTTP $HTTP_CODE"
  if [ -n "$HTTP_BODY" ]; then
    detalle "   $(printf '%s' "$HTTP_BODY" | head -c 260)"
  fi
}

# Extrae un campo del ultimo HTTP_BODY. Usa jq si esta, si no cae a python3.
campo() {
  local ruta="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$HTTP_BODY" | jq -r "$ruta" 2>/dev/null
  else
    printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(''); sys.exit()
ruta='''$ruta'''.lstrip('.')
for parte in [p for p in ruta.replace('[',' ').replace(']',' ').split() if p]:
    try:
        d = d[int(parte)] if parte.isdigit() else d.get(parte)
    except Exception:
        d = None
    if d is None: break
print('' if d is None else d)
" 2>/dev/null
  fi
}

# ------------------------------------------------------------------ interactivo
# preguntar VARIABLE "texto" "valor por defecto"
#
# Si la variable ya tiene valor (porque vino por argumento) no pregunta nada. Si la terminal
# es interactiva, pregunta. Si no lo es (por ejemplo dentro de un pipe o de correr-todo.sh),
# usa el valor por defecto sin bloquearse esperando input.
preguntar() {
  local var="$1" texto="$2" defecto="${3:-}" valor
  eval "valor=\${$var:-}"
  [ -n "$valor" ] && return 0

  if [ ! -t 0 ]; then
    eval "$var=\"\$defecto\""
    return 0
  fi

  if [ -n "$defecto" ]; then
    printf "  %s [%s]: " "$texto" "$defecto" >&2
  else
    printf "  %s: " "$texto" >&2
  fi
  read -r valor
  [ -z "$valor" ] && valor="$defecto"
  eval "$var=\"\$valor\""
}

# Muestra la ayuda del script y termina, si el primer argumento la pide.
ayuda() {
  case "${1:-}" in
    -h|--help|help|ayuda)
      sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d' >&2
      exit 0 ;;
  esac
}

# Imprime lo que se creo y devuelve el id, para poder encadenar scripts.
creado() {
  local que="$1" id="$2"
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    ok "$que creado con id: ${C_BOLD}$id${C_OFF}"
    return 0
  fi
  falla "no se pudo crear el $que (HTTP $HTTP_CODE)"
  return 1
}

# ------------------------------------------------------------------ estado
# Los scripts se pasan IDs entre si por un archivo, asi cada uno corre solo.
DIR_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVO_ESTADO="$DIR_BASE/.estado"

guardar() {
  local clave="$1" valor="$2"
  [ -f "$ARCHIVO_ESTADO" ] || : > "$ARCHIVO_ESTADO"
  grep -v "^${clave}=" "$ARCHIVO_ESTADO" > "$ARCHIVO_ESTADO.tmp" 2>/dev/null || :
  mv "$ARCHIVO_ESTADO.tmp" "$ARCHIVO_ESTADO"
  echo "${clave}=${valor}" >> "$ARCHIVO_ESTADO"
  detalle "guardado: ${clave}=${valor}"
}

cargar_estado() {
  if [ -f "$ARCHIVO_ESTADO" ]; then
    # shellcheck disable=SC1090
    . "$ARCHIVO_ESTADO"
  fi
}

# Corta el script si falta un ID que tenia que haber dejado el seed.
exigir_estado() {
  local clave="$1"
  eval "local valor=\${$clave:-}"
  if [ -z "$valor" ]; then
    echo ""
    echo "${C_ERR}Falta '$clave' en el estado.${C_OFF}"
    echo "Corre primero:  ./01-seed.sh"
    exit 1
  fi
}

# ------------------------------------------------------------------ config
cargar_config() {
  if [ -f "$DIR_BASE/config.sh" ]; then
    # shellcheck disable=SC1090
    . "$DIR_BASE/config.sh"
  else
    echo "${C_ERR}No existe config.sh${C_OFF}"
    echo "Copialo del ejemplo:  cp config.sh.example config.sh"
    exit 1
  fi
}

cargar_config
cargar_estado

# Prefijo para poder identificar y limpiar despues todo lo que crean los scripts.
PREFIJO="${PREFIJO:-TEST}"
