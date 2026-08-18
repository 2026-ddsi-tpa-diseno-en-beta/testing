#!/usr/bin/env bash
# Crea una insignia y una mision en Incentivos, y opcionalmente le asigna la mision a un donador.
#
# Las 4 misiones del enunciado y lo que pide cada una:
#   COMPLETITUD            donaciones en 3 categorias distintas    OCASIONAL     -> COLABORADOR
#   DONACIONES_EXITOSAS    20 donaciones en estado ACEPTADA        COLABORADOR   -> TRANSFORMADOR
#   DONACIONES_ASCENDENTES ultimas 5 en tendencia creciente        COLABORADOR   -> SALVADOR
#   REVOLUCION_DONADORA    mas de 10 donaciones de mas de 50 u.    TRANSFORMADOR -> REVOLUCIONARIO
#
# Uso:
#   ./crear-mision.sh
#   ./crear-mision.sh --tipo DONACIONES_ASCENDENTES
#   ./crear-mision.sh --tipo COMPLETITUD --asignar-a <donadorID>
#   ./crear-mision.sh --tipo REVOLUCION_DONADORA --desde TRANSFORMADOR --hasta REVOLUCIONARIO
set -u
. "$(dirname "$0")/lib/comun.sh"
ayuda "${1:-}"

TIPO=""; DESDE=""; HASTA=""; NOMBRE=""; ASIGNAR_A=""; GUARDAR_COMO="MISION"

while [ $# -gt 0 ]; do
  case "$1" in
    --tipo)          TIPO="$2"; shift 2 ;;
    --desde)         DESDE="$2"; shift 2 ;;
    --hasta)         HASTA="$2"; shift 2 ;;
    --nombre)        NOMBRE="$2"; shift 2 ;;
    --asignar-a)     ASIGNAR_A="$2"; shift 2 ;;
    --guardar-como)  GUARDAR_COMO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1  (./crear-mision.sh --help)" >&2; exit 1 ;;
  esac
done

titulo "CREAR UNA MISION"

if [ -t 0 ] && [ -z "$TIPO" ]; then
  detalle "tipos disponibles:"
  detalle "  COMPLETITUD             3 categorias distintas"
  detalle "  DONACIONES_EXITOSAS     20 donaciones ACEPTADA"
  detalle "  DONACIONES_ASCENDENTES  ultimas 5 en tendencia creciente"
  detalle "  REVOLUCION_DONADORA     mas de 10 donaciones de mas de 50 unidades"
fi

preguntar TIPO "Tipo de mision" "COMPLETITUD"

# Cada tipo tiene su transicion de categoria segun el enunciado.
case "$TIPO" in
  COMPLETITUD)            DEF_DESDE="OCASIONAL";     DEF_HASTA="COLABORADOR" ;;
  DONACIONES_EXITOSAS)    DEF_DESDE="COLABORADOR";   DEF_HASTA="TRANSFORMADOR" ;;
  DONACIONES_ASCENDENTES) DEF_DESDE="COLABORADOR";   DEF_HASTA="SALVADOR" ;;
  REVOLUCION_DONADORA)    DEF_DESDE="TRANSFORMADOR"; DEF_HASTA="REVOLUCIONARIO" ;;
  *)                      DEF_DESDE="OCASIONAL";     DEF_HASTA="COLABORADOR"
                          aviso "tipo '$TIPO' no es uno de los 4 del enunciado" ;;
esac

preguntar DESDE  "Categoria de inicio" "$DEF_DESDE"
preguntar HASTA  "Categoria de fin"    "$DEF_HASTA"
preguntar NOMBRE "Nombre de la mision" "$PREFIJO-$TIPO-$(date +%H%M%S)"

paso "Creando la insignia que otorga la mision"
req POST "$URL_INCENTIVOS/insignias" \
  "{\"nombre\":\"$PREFIJO-Insignia-$TIPO-$(date +%H%M%S)\",\"descripcion\":\"insignia de $TIPO\"}"
INSIGNIA_NUEVA=$(campo '.id')
creado "insignia" "$INSIGNIA_NUEVA" || { resumen; exit 1; }

paso "POST /misiones"
detalle "$TIPO:  $DESDE -> $HASTA"
req POST "$URL_INCENTIVOS/misiones" \
  "{\"nombre\":\"$NOMBRE\",\"insigniaID\":\"$INSIGNIA_NUEVA\",\"categoriaInicio\":\"$DESDE\",\"categoriaFin\":\"$HASTA\",\"tipo\":\"$TIPO\"}"

MISION_NUEVA=$(campo '.id')
creado "mision" "$MISION_NUEVA" || { resumen; exit 1; }
MISION_JSON="$HTTP_BODY"

# ------------------------------------------------ asignar
if [ -z "$ASIGNAR_A" ] && [ -t 0 ]; then
  preguntar ASIGNAR_A "ID del donador al que asignarsela (vacio = a ninguno)" ""
fi

if [ -n "$ASIGNAR_A" ]; then
  paso "Asignandola al donador $ASIGNAR_A"
  req POST "$URL_INCENTIVOS/misiones/donador/$ASIGNAR_A" "$MISION_JSON"
  case "$HTTP_CODE" in
    200|201|204) ok "mision asignada" ;;
    *)           falla "no se pudo asignar (HTTP $HTTP_CODE)" ;;
  esac

  paso "Verificando que quede como mision en curso"
  req GET "$URL_INCENTIVOS/misiones/donador/$ASIGNAR_A"
  if [ "$HTTP_CODE" = "200" ] && [ -n "$HTTP_BODY" ]; then
    ok "mision en curso: $(campo '.nombre')"
  else
    aviso "no devuelve mision en curso (HTTP $HTTP_CODE)"
    detalle "el enunciado pide que lance error si el donador no tiene ninguna asignada"
  fi
fi

guardar INSIGNIA "$INSIGNIA_NUEVA"
guardar "$GUARDAR_COMO" "$MISION_NUEVA"

echo "" >&2
echo "  Que hace falta para completarla:" >&2
case "$TIPO" in
  COMPLETITUD)
    echo "    donaciones en 3 categorias distintas. Con los scripts:" >&2
    echo "      ./crear-categoria.sh --nombre CatA   (x3, y un producto en cada una)" >&2
    echo "      ./donar.sh --producto <cada uno> --cantidad 5" >&2 ;;
  DONACIONES_ASCENDENTES)
    echo "    5 donaciones con cantidades crecientes:" >&2
    echo "      ./donar.sh --veces 5 --cantidad 10 --incremental" >&2 ;;
  DONACIONES_EXITOSAS)
    echo "    20 donaciones que lleguen a ACEPTADA (hay que reportar la entrega de cada una)" >&2 ;;
  REVOLUCION_DONADORA)
    echo "    mas de 10 donaciones de mas de 50 unidades:" >&2
    echo "      ./donar.sh --veces 11 --cantidad 60" >&2 ;;
esac
echo "" >&2
echo "  Despues, para evaluarla:" >&2
echo "    curl -X POST $URL_INCENTIVOS/procesamiento/${ASIGNAR_A:-<donadorID>}" >&2

echo "$MISION_NUEVA"
resumen
