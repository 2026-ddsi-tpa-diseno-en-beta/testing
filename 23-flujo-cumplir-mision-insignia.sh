#!/usr/bin/env bash
# FLUJO INCENTIVOS - CUMPLIR UNA MISION Y OTORGAR INSIGNIA
#
# Demuestra el caso completo:
#   1. se crea un donador nuevo
#   2. se crea una insignia y una mision COMPLETITUD
#   3. se asigna la mision al donador
#   4. se registran 3 donaciones en 3 categorias distintas
#   5. se procesa el donador en Incentivos
#   6. la mision deja de estar en curso y aparece la insignia del donador
#
# Uso:
#   ./23-flujo-cumplir-mision-insignia.sh
#
# Nota: para COMPLETITUD, la implementacion actual de Incentivos mira categorias distintas
# en el historial de donaciones. No necesita que esas donaciones esten ACEPTADA.
set -u
. "$(dirname "$0")/lib/comun.sh"

exigir_estado DEPOSITO

SELLO="$(date +%m%d-%H%M%S)"
SELLO_DOC="$(date +%m%d%H%M%S)"

contar_lista() {
  printf '%s' "$1" | python_json -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d, list) else 0)
except Exception:
    print(0)
" 2>/dev/null
}

json_contiene_id() {
  local buscado="$1"
  printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
buscado='''$buscado'''
try:
    d=json.load(sys.stdin)
except Exception:
    print('no'); sys.exit()
if isinstance(d, list):
    print('si' if any(str(x.get('id')) == buscado for x in d if isinstance(x, dict)) else 'no')
else:
    print('si' if str(d.get('id')) == buscado else 'no')
" 2>/dev/null
}

crear_categoria_mision() {
  local indice="$1" variable="$2" clave="$3" nombre descripcion nombre_json descripcion_json id
  nombre="$PREFIJO Mision Categoria $indice $SELLO"
  descripcion="categoria para cumplir mision completitud"
  nombre_json=$(json_escape "$nombre")
  descripcion_json=$(json_escape "$descripcion")

  paso "Categoria $indice para la mision"
  req POST "$URL_DONACIONES/categorias" \
    "{\"nombre\":\"$nombre_json\",\"descripcion\":\"$descripcion_json\"}"
  id=$(campo '.id')
  creado "categoria $indice" "$id" || { resumen; exit 1; }
  guardar "$clave" "$id"
  eval "$variable=\"\$id\""
}

crear_producto_mision() {
  local indice="$1" categoria="$2" variable="$3" clave="$4" nombre descripcion nombre_json descripcion_json id
  nombre="$PREFIJO Mision Producto $indice $SELLO"
  descripcion="producto para mision completitud"
  nombre_json=$(json_escape "$nombre")
  descripcion_json=$(json_escape "$descripcion")

  paso "Producto $indice en categoria $categoria"
  req POST "$URL_DONACIONES/productos" \
    "{\"nombre\":\"$nombre_json\",\"descripcion\":\"$descripcion_json\",\"categoriaID\":\"$categoria\"}"
  id=$(campo '.id')
  creado "producto $indice" "$id" || { resumen; exit 1; }
  guardar "$clave" "$id"
  eval "$variable=\"\$id\""
}

crear_donacion_mision() {
  local indice="$1" producto="$2" cantidad="$3" variable="$4" clave="$5" descripcion_json id estado
  descripcion_json=$(json_escape "$PREFIJO donacion mision categoria $indice")

  paso "Donacion $indice: producto $producto, cantidad $cantidad"
  req POST "$URL_DONACIONES/donaciones" \
    "{\"donadorID\":\"$DONADOR_MISION\",\"depositoID\":\"$DEPOSITO\",\"descripcion\":\"$descripcion_json\",\"productoID\":\"$producto\",\"cantidad\":$cantidad}"
  case "$HTTP_CODE" in
    200|201)
      id=$(campo '.id')
      estado=$(campo '.estado')
      ok "donacion creada: $id ($estado)"
      guardar "$clave" "$id"
      eval "$variable=\"\$id\""
      ;;
    *)
      falla "no se pudo crear la donacion $indice (HTTP $HTTP_CODE)"
      resumen; exit 1
      ;;
  esac
}

titulo "FLUJO INCENTIVOS - CUMPLIR MISION Y OTORGAR INSIGNIA"
echo "Se va a completar una mision COMPLETITUD con 3 categorias distintas."
echo "Deposito usado para registrar las donaciones: $DEPOSITO"

# ============================================================ donador
titulo "1. Donador de prueba"

paso "Crear un donador limpio"
req POST "$URL_DONADORES/donadores" \
  "{\"nombre\":\"Mara\",\"apellido\":\"Completitud\",\"edad\":30,\"email\":\"mara.completitud.$SELLO@donatrack.org.ar\",\"nroDocumento\":\"$SELLO_DOC\",\"domicilio\":\"Calle Mision 123\"}"
DONADOR_MISION=$(campo '.id')
creado "donador" "$DONADOR_MISION" || { resumen; exit 1; }
guardar DONADOR_MISION "$DONADOR_MISION"
verificar "estado inicial del donador" "VERIFICADO" "$(campo '.estado')"

# ============================================================ mision
titulo "2. Mision e insignia"

paso "Crear la insignia que se deberia ganar"
INSIGNIA_NOMBRE_JSON=$(json_escape "$PREFIJO Insignia Completitud $SELLO")
INSIGNIA_DESC_JSON=$(json_escape "Se otorga al donar en tres categorias distintas")
req POST "$URL_INCENTIVOS/insignias" \
  "{\"nombre\":\"$INSIGNIA_NOMBRE_JSON\",\"descripcion\":\"$INSIGNIA_DESC_JSON\"}"
INSIGNIA_MISION=$(campo '.id')
creado "insignia" "$INSIGNIA_MISION" || { resumen; exit 1; }
guardar INSIGNIA_MISION "$INSIGNIA_MISION"

paso "Crear mision COMPLETITUD"
MISION_NOMBRE_JSON=$(json_escape "$PREFIJO Mision Completitud $SELLO")
req POST "$URL_INCENTIVOS/misiones" \
  "{\"nombre\":\"$MISION_NOMBRE_JSON\",\"insigniaID\":\"$INSIGNIA_MISION\",\"categoriaInicio\":\"OCASIONAL\",\"categoriaFin\":\"COLABORADOR\",\"tipo\":\"COMPLETITUD\"}"
MISION_CUMPLIDA=$(campo '.id')
creado "mision" "$MISION_CUMPLIDA" || { resumen; exit 1; }
guardar MISION_CUMPLIDA "$MISION_CUMPLIDA"
MISION_JSON="$HTTP_BODY"

paso "Asignar la mision al donador"
req POST "$URL_INCENTIVOS/misiones/donador/$DONADOR_MISION" "$MISION_JSON"
case "$HTTP_CODE" in
  200|201|204) ok "mision asignada" ;;
  *)           falla "no se pudo asignar la mision (HTTP $HTTP_CODE)"; resumen; exit 1 ;;
esac

paso "Verificar que aparece como mision en curso"
req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR_MISION"
if [ "$HTTP_CODE" = "200" ]; then
  verificar "mision en curso" "$MISION_CUMPLIDA" "$(campo '.id')"
else
  falla "no devuelve la mision en curso (HTTP $HTTP_CODE)"
fi

paso "Antes de donar todavia no tiene insignias"
req GET "$URL_INCENTIVOS/insignias/donador/$DONADOR_MISION"
INSIGNIAS_ANTES=$(contar_lista "$HTTP_BODY")
verificar "insignias antes de procesar" "0" "${INSIGNIAS_ANTES:-0}"

# ============================================================ donaciones
titulo "3. Tres donaciones en tres categorias distintas"

crear_categoria_mision 1 CAT_MISION_1 CATEGORIA_MISION_1
crear_producto_mision 1 "$CAT_MISION_1" PROD_MISION_1 PRODUCTO_MISION_1
crear_donacion_mision 1 "$PROD_MISION_1" 5 DONACION_MISION_1 DONACION_MISION_1

crear_categoria_mision 2 CAT_MISION_2 CATEGORIA_MISION_2
crear_producto_mision 2 "$CAT_MISION_2" PROD_MISION_2 PRODUCTO_MISION_2
crear_donacion_mision 2 "$PROD_MISION_2" 10 DONACION_MISION_2 DONACION_MISION_2

crear_categoria_mision 3 CAT_MISION_3 CATEGORIA_MISION_3
crear_producto_mision 3 "$CAT_MISION_3" PROD_MISION_3 PRODUCTO_MISION_3
crear_donacion_mision 3 "$PROD_MISION_3" 15 DONACION_MISION_3 DONACION_MISION_3

paso "Confirmar que Donaciones ve el historial del donador"
req GET "$URL_DONACIONES/donaciones?donadorID=$DONADOR_MISION&fecha=2025-01-01"
DONACIONES_VISIBLES=$(contar_lista "$HTTP_BODY")
if [ "${DONACIONES_VISIBLES:-0}" -ge 3 ]; then
  ok "Donaciones devuelve $DONACIONES_VISIBLES donacion(es) para el donador"
else
  falla "Donaciones devuelve solo ${DONACIONES_VISIBLES:-0}; Incentivos no va a poder completar la mision"
fi

# ============================================================ procesamiento
titulo "4. Procesamiento de Incentivos"

paso "Procesar el donador"
req POST "$URL_INCENTIVOS/procesamiento/$DONADOR_MISION"
case "$HTTP_CODE" in
  200|201|204) ok "donador procesado" ;;
  *)           falla "no se pudo procesar el donador (HTTP $HTTP_CODE)" ;;
esac

paso "La insignia de la mision tiene que aparecer en Incentivos"
req GET "$URL_INCENTIVOS/insignias/donador/$DONADOR_MISION"
INSIGNIAS_DESPUES=$(contar_lista "$HTTP_BODY")
TIENE_INSIGNIA=$(json_contiene_id "$INSIGNIA_MISION")
detalle "insignias despues: ${INSIGNIAS_DESPUES:-0}"
if [ "$TIENE_INSIGNIA" = "si" ]; then
  ok "la insignia $INSIGNIA_MISION fue otorgada por completar la mision"
else
  falla "la insignia $INSIGNIA_MISION no aparece para el donador"
fi

paso "La mision completada ya no deberia estar en curso"
req GET "$URL_INCENTIVOS/misiones/donador/$DONADOR_MISION"
case "$HTTP_CODE" in
  204) ok "no hay mision en curso: la COMPLETITUD quedo completada" ;;
  200) falla "todavia devuelve una mision en curso: $(campo '.id')" ;;
  *)   falla "respuesta inesperada al consultar mision en curso (HTTP $HTTP_CODE)" ;;
esac

# ============================================================ integracion DYE
titulo "5. Estadisticas integradas desde Donadores"

paso "Donadores y Entidades deberia reflejar la insignia en /estadisticas"
req GET "$URL_DONADORES/donadores/$DONADOR_MISION/estadisticas"
if [ "$HTTP_CODE" = "200" ]; then
  TIENE_EN_DYE=$(printf '%s' "$HTTP_BODY" | python_json -c "
import json,sys
buscado='''$INSIGNIA_MISION'''
try:
    d=json.load(sys.stdin)
    ids=d.get('insigniasID') or []
    print('si' if buscado in [str(x) for x in ids] else 'no')
except Exception:
    print('no')
" 2>/dev/null)
  detalle "misionActualID: $(campo '.misionActualID')"
  detalle "insigniasID:    $(campo '.insigniasID')"
  [ "$TIENE_EN_DYE" = "si" ] \
    && ok "Donadores muestra la insignia que viene de Incentivos" \
    || falla "Incentivos tiene la insignia, pero /estadisticas no la muestra"
else
  falla "no se pudo leer /estadisticas del donador (HTTP $HTTP_CODE)"
fi

echo ""
echo "IDs principales:"
echo "  DONADOR_MISION=$DONADOR_MISION"
echo "  MISION_CUMPLIDA=$MISION_CUMPLIDA"
echo "  INSIGNIA_MISION=$INSIGNIA_MISION"
echo ""
echo "Para mostrarlo despues:"
echo "  ./13-flujo-estadisticas.sh $DONADOR_MISION"
echo "  ./ver-donador.sh $DONADOR_MISION --detalle"

resumen
