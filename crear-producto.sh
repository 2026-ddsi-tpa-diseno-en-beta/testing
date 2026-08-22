#!/usr/bin/env bash
# Crea UN producto, con o sin identificador.
#
# Ojo con la validacion del identificador, que es lo que mas confunde:
#   CODIGODEBARRAS -> valido solo si la DESCRIPCION tiene 3 palabras o mas
#   QR             -> valido solo si el NOMBRE tiene una cantidad PAR de letras
# El script te avisa antes de mandar si lo que pusiste va a pasar la validacion.
#
# Uso:
#   ./crear-producto.sh
#       te pregunta todo y te muestra las categorias que hay
#
#   ./crear-producto.sh --nombre "Fideos" --descripcion "medio kilo de fideos" --categoria 12
#
#   ./crear-producto.sh --nombre Mesa --descripcion "una mesa" --categoria 12 --sin-identificador
#       el identificador es opcional segun el enunciado
#
#   ./crear-producto.sh --nombre Mesa --descripcion "mesa de roble grande" \
#                       --categoria 12 --identificador 9
#
#   ./crear-producto.sh --nombre Mesa --descripcion "mesa grande de roble" \
#                       --categoria 12 --tipo-identificador CODIGODEBARRAS
#       crea el identificador en el momento y lo asocia
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

NOMBRE=""; DESCRIPCION=""; CATEGORIA_ARG=""; SUBCATEGORIA_ARG=""
IDENTIFICADOR_ARG=""; TIPO_IDENT=""; SIN_IDENT="no"; GUARDAR_COMO="PRODUCTO"

while [ $# -gt 0 ]; do
  case "$1" in
    --nombre)             NOMBRE="$2"; shift 2 ;;
    --descripcion)        DESCRIPCION="$2"; shift 2 ;;
    --categoria)          CATEGORIA_ARG="$2"; shift 2 ;;
    --subcategoria)       SUBCATEGORIA_ARG="$2"; shift 2 ;;
    --identificador)      IDENTIFICADOR_ARG="$2"; shift 2 ;;
    --tipo-identificador) TIPO_IDENT="$2"; shift 2 ;;
    --sin-identificador)  SIN_IDENT="si"; shift ;;
    --guardar-como)       GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-producto.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UN PRODUCTO"

# Muestra las categorias disponibles cuando se usa interactivo.
if [ -z "$CATEGORIA_ARG" ] && [ -t 0 ]; then
  req GET "$URL_DONACIONES/categorias" >/dev/null 2>&1
  if [ "$HTTP_CODE" = "200" ]; then
    detalle "categorias que existen:"
    printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d[-10:]:
    marca = '  (subcategoria de ' + str(x.get('categoriaPadreID')) + ')' if x.get('categoriaPadreID') else '  (raiz)'
    print('    ' + str(x.get('id')) + '  ' + str(x.get('nombre')) + marca)
" >&2 2>/dev/null
  fi
fi

preguntar NOMBRE        "Nombre del producto" "$PREFIJO Producto"
preguntar DESCRIPCION   "Descripcion"         "producto creado a mano"
preguntar CATEGORIA_ARG "ID de categoria"     "${CATEGORIA:-}"

# La categoria es obligatoria.
if [ -z "$CATEGORIA_ARG" ]; then
  falla "hace falta una categoria: el modulo no acepta productos sin clasificar"
  detalle "crea una con:  ./crear-categoria.sh --nombre Alimentos"
  resumen; exit 1
fi

# Si la categoria elegida tiene subcategorias, hay que elegir una: la subcategoria es la
# unidad minima de asignacion, asi que un producto no puede quedar colgado del padre.
req GET "$URL_DONACIONES/categorias/$CATEGORIA_ARG/subcategorias" >/dev/null 2>&1
HIJAS="$HTTP_BODY"
CUANTAS_HIJAS=$(printf '%s' "$HIJAS" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)
except Exception: print(0)
" 2>/dev/null)

if [ "${CUANTAS_HIJAS:-0}" -gt 0 ]; then
  detalle "la categoria $CATEGORIA_ARG tiene ${CUANTAS_HIJAS} subcategoria(s): hay que elegir una"
  if [ -z "$SUBCATEGORIA_ARG" ] && [ -t 0 ]; then
    printf '%s' "$HIJAS" | python_json -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d: print('    ' + str(x.get('id')) + '  ' + str(x.get('nombre')))
" >&2 2>/dev/null
  fi
  preguntar SUBCATEGORIA_ARG "ID de subcategoria (obligatoria para esta categoria)" ""
  if [ -z "$SUBCATEGORIA_ARG" ]; then
    falla "la categoria $CATEGORIA_ARG tiene subcategorias y no elegiste ninguna"
    detalle "el modulo lo rechaza: la subcategoria es la unidad minima de asignacion"
    resumen; exit 1
  fi
else
  detalle "la categoria $CATEGORIA_ARG no tiene subcategorias: clasifica el producto directamente"
  SUBCATEGORIA_ARG=""
fi

# ------------------------------------------------ chequeo de la validacion
LETRAS_NOMBRE=$(printf '%s' "$NOMBRE" | tr -cd '[:alpha:]' | wc -c | tr -d ' ')
PALABRAS_DESC=$(printf '%s' "$DESCRIPCION" | wc -w | tr -d ' ')
PAR="no"; [ $((LETRAS_NOMBRE % 2)) -eq 0 ] && PAR="si"

paso "Como queda contra la validacion de identificadores"
detalle "nombre '$NOMBRE': $LETRAS_NOMBRE letras -> $([ "$PAR" = "si" ] && echo "PAR, sirve para QR" || echo "IMPAR, NO sirve para QR")"
detalle "descripcion: $PALABRAS_DESC palabras -> $([ "$PALABRAS_DESC" -ge 3 ] && echo "sirve para CODIGODEBARRAS" || echo "NO sirve para CODIGODEBARRAS, hacen falta 3 o mas")"

# ------------------------------------------------ identificador
IDENTIFICADOR=""
if [ "$SIN_IDENT" = "si" ]; then
  detalle "se crea sin identificador (es opcional segun el enunciado)"
elif [ -n "$IDENTIFICADOR_ARG" ]; then
  IDENTIFICADOR="$IDENTIFICADOR_ARG"
  req GET "$URL_DONACIONES/identificadores/$IDENTIFICADOR"
  if [ "$HTTP_CODE" = "200" ]; then
    TIPO_EXISTENTE=$(campo '.tipo')
    detalle "identificador $IDENTIFICADOR es de tipo $TIPO_EXISTENTE"
    case "$TIPO_EXISTENTE" in
      QR)             [ "$PAR" = "si" ] || aviso "el nombre tiene letras impares: la validacion QR va a fallar" ;;
      CODIGODEBARRAS) [ "$PALABRAS_DESC" -ge 3 ] || aviso "la descripcion tiene menos de 3 palabras: la validacion va a fallar" ;;
    esac
  else
    aviso "no se pudo leer el identificador $IDENTIFICADOR (HTTP $HTTP_CODE)"
  fi
elif [ -n "$TIPO_IDENT" ]; then
  paso "Creando el identificador $TIPO_IDENT"
  req POST "$URL_DONACIONES/identificadores" \
    "{\"tipo\":\"$TIPO_IDENT\",\"descripcion\":\"identificador para $NOMBRE\"}"
  IDENTIFICADOR=$(campo '.id')
  creado "identificador" "$IDENTIFICADOR" || true
else
  if [ -t 0 ]; then
    preguntar TIPO_IDENT "Tipo de identificador (QR / CODIGODEBARRAS / vacio para ninguno)" ""
    if [ -n "$TIPO_IDENT" ]; then
      req POST "$URL_DONACIONES/identificadores" \
        "{\"tipo\":\"$TIPO_IDENT\",\"descripcion\":\"identificador para $NOMBRE\"}"
      IDENTIFICADOR=$(campo '.id')
      creado "identificador" "$IDENTIFICADOR" || true
    fi
  fi
fi

# ------------------------------------------------ alta
CUERPO="{\"nombre\":\"$NOMBRE\",\"descripcion\":\"$DESCRIPCION\""
[ -n "$CATEGORIA_ARG" ]    && CUERPO="$CUERPO,\"categoriaID\":\"$CATEGORIA_ARG\""
[ -n "$SUBCATEGORIA_ARG" ] && CUERPO="$CUERPO,\"subcategoriaID\":\"$SUBCATEGORIA_ARG\""
[ -n "$IDENTIFICADOR" ]    && CUERPO="$CUERPO,\"identificadorID\":\"$IDENTIFICADOR\""
CUERPO="$CUERPO}"

paso "POST /productos"
req POST "$URL_DONACIONES/productos" "$CUERPO"

PRODUCTO_NUEVO=$(campo '.id')
if ! creado "producto" "$PRODUCTO_NUEVO"; then
  MENSAJE=$(campo '.message')
  echo "" >&2
  [ -n "$MENSAJE" ] && [ "$MENSAJE" != "null" ] && echo "    lo que respondio el modulo: ${C_WARN}$MENSAJE${C_OFF}" >&2
  echo "" >&2
  echo "    Causas posibles, en orden de probabilidad:" >&2
  echo "    - Falta la categoria, o la categoria elegida tiene subcategorias y hay que" >&2
  echo "      elegir una de ellas (la subcategoria es la unidad minima de asignacion)." >&2
  echo "    - La validacion del identificador:" >&2
  echo "        CODIGODEBARRAS necesita una descripcion de 3 palabras o mas" >&2
  echo "        QR necesita que el nombre tenga una cantidad par de letras" >&2
  echo "      Se puede crear sin identificador con:  --sin-identificador" >&2
  resumen; exit 1
fi

detalle "categoria:     $(campo '.categoriaID')"
detalle "subcategoria:  $(campo '.subcategoriaID')"
detalle "identificador: $(campo '.identificadorID')"

guardar "$GUARDAR_COMO" "$PRODUCTO_NUEVO"

echo "" >&2
echo "  Para usarlo:" >&2
echo "    ./donar.sh --producto $PRODUCTO_NUEVO --cantidad 40" >&2
echo "    ./crear-necesidad.sh --producto $PRODUCTO_NUEVO --cantidad 100" >&2

echo "$PRODUCTO_NUEVO"
resumen
