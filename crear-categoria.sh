#!/usr/bin/env bash
# Crea UNA categoria, o una subcategoria si le pasas el padre.
#
# La subcategoria es la unidad minima de asignacion del sistema: "Alimentos" es la categoria
# y "fideos", "arroz", "legumbres" son sus subcategorias. La jerarquia es de un solo nivel.
#
# Uso:
#   ./crear-categoria.sh
#       te pregunta los campos
#
#   ./crear-categoria.sh --nombre Alimentos
#       categoria raiz
#
#   ./crear-categoria.sh --nombre Fideos --padre 12
#       subcategoria de la categoria 12
#
#   ./crear-categoria.sh --nombre Fideos --padre 12 --guardar-como SUB_FIDEOS
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

NOMBRE=""; DESCRIPCION=""; PADRE=""; GUARDAR_COMO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --nombre)        NOMBRE="$2"; shift 2 ;;
    --descripcion)   DESCRIPCION="$2"; shift 2 ;;
    --padre)         PADRE="$2"; shift 2 ;;
    --guardar-como)  GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-categoria.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UNA CATEGORIA"

# Si hay categorias raiz cargadas, se las muestra para poder elegir el padre.
if [ -z "$PADRE" ] && [ -t 0 ]; then
  req GET "$URL_DONACIONES/categorias" >/dev/null 2>&1
  if [ "$HTTP_CODE" = "200" ]; then
    RAICES=$(printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
raices=[x for x in d if not x.get('categoriaPadreID')]
for x in raices[-8:]:
    print('    ' + str(x.get('id')) + '  ' + str(x.get('nombre')))
" 2>/dev/null)
    if [ -n "$RAICES" ]; then
      detalle "categorias raiz que ya existen (podes usar una como padre):"
      printf '%s\n' "$RAICES" >&2
    fi
  fi
fi

preguntar NOMBRE      "Nombre de la categoria"                    "$PREFIJO-Categoria-$(date +%H%M%S)"
preguntar DESCRIPCION "Descripcion"                               "categoria creada a mano"
preguntar PADRE       "ID de la categoria padre (vacio = raiz)"   ""

CUERPO="{\"nombre\":\"$NOMBRE\",\"descripcion\":\"$DESCRIPCION\""
if [ -n "$PADRE" ]; then
  CUERPO="$CUERPO,\"categoriaPadreID\":\"$PADRE\""
  detalle "se va a crear como SUBCATEGORIA de $PADRE"
else
  detalle "se va a crear como categoria RAIZ"
fi
CUERPO="$CUERPO}"

paso "POST /categorias"
req POST "$URL_DONACIONES/categorias" "$CUERPO"

CATEGORIA=$(campo '.id')
creado "categoria" "$CATEGORIA" || { resumen; exit 1; }

ES_SUB=$(campo '.esSubcategoria')
if [ -n "$PADRE" ]; then
  verificar "quedo marcada como subcategoria" "True" "$(printf '%s' "$ES_SUB" | sed 's/true/True/')"
  verificar "el padre es el indicado" "$PADRE" "$(campo '.categoriaPadreID')"
  paso "Subcategorias que tiene ahora el padre $PADRE"
  req GET "$URL_DONACIONES/categorias/$PADRE/subcategorias"
  printf '%s' "$HTTP_BODY" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d: print('      ' + str(x.get('id')) + '  ' + str(x.get('nombre')))
" >&2 2>/dev/null
else
  [ -z "$GUARDAR_COMO" ] && GUARDAR_COMO="CATEGORIA"
fi

[ -z "$GUARDAR_COMO" ] && GUARDAR_COMO="SUBCATEGORIA"
guardar "$GUARDAR_COMO" "$CATEGORIA"

echo "" >&2
if [ -n "$PADRE" ]; then
  echo "  Para crear un producto en esta subcategoria:" >&2
  echo "    ./crear-producto.sh --categoria $PADRE --subcategoria $CATEGORIA" >&2
else
  echo "  Para colgarle una subcategoria:" >&2
  echo "    ./crear-categoria.sh --nombre Fideos --padre $CATEGORIA" >&2
fi

echo "$CATEGORIA"
resumen
