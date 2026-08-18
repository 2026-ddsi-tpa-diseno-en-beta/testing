#!/usr/bin/env bash
# Carga en las bases todas las precondiciones que necesitan los flujos.
# Guarda los IDs en .estado para que los scripts 10-14 los usen.
#
# El orden importa: el producto se crea primero en Donaciones porque Donadores y
# Entidades valida contra ese modulo al registrar una necesidad.
set -u
. "$(dirname "$0")/lib/comun.sh"

SELLO="$(date +%m%d-%H%M%S)"

titulo "SEED DE PRECONDICIONES"
echo "Todo lo que se cree lleva el prefijo '$PREFIJO' para poder limpiarlo despues."
echo "Sello de esta corrida: $SELLO"

# ============================================================ DONACIONES
titulo "1/4  DONACIONES: categoria, subcategoria, identificador y producto"

paso "Categoria raiz"
req POST "$URL_DONACIONES/categorias" \
  "{\"nombre\":\"$PREFIJO-Alimentos-$SELLO\",\"descripcion\":\"categoria de prueba\"}"
CATEGORIA=$(campo '.id')
if [ -n "$CATEGORIA" ] && [ "$CATEGORIA" != "null" ]; then
  ok "categoria creada: $CATEGORIA"; guardar CATEGORIA "$CATEGORIA"
else
  falla "no se pudo crear la categoria"; resumen; exit 1
fi

paso "Subcategoria (unidad minima de asignacion)"
req POST "$URL_DONACIONES/categorias" \
  "{\"nombre\":\"$PREFIJO-Fideos-$SELLO\",\"descripcion\":\"subcategoria de prueba\",\"categoriaPadreID\":\"$CATEGORIA\"}"
SUBCATEGORIA=$(campo '.id')
if [ -n "$SUBCATEGORIA" ] && [ "$SUBCATEGORIA" != "null" ]; then
  ok "subcategoria creada: $SUBCATEGORIA"; guardar SUBCATEGORIA "$SUBCATEGORIA"
else
  aviso "no se pudo crear la subcategoria, se sigue sin ella"
  SUBCATEGORIA=""
fi

paso "Identificador de codigo de barras"
req POST "$URL_DONACIONES/identificadores" \
  "{\"tipo\":\"CODIGODEBARRAS\",\"descripcion\":\"identificador de prueba\"}"
IDENTIFICADOR=$(campo '.id')
[ -n "$IDENTIFICADOR" ] && [ "$IDENTIFICADOR" != "null" ] \
  && { ok "identificador creado: $IDENTIFICADOR"; guardar IDENTIFICADOR "$IDENTIFICADOR"; } \
  || aviso "no se pudo crear el identificador"

paso "Producto"
detalle "la descripcion tiene 4 palabras: valida para codigo de barras (pide 3 o mas)"
CUERPO_PRODUCTO="{\"nombre\":\"$PREFIJO Fideos\",\"descripcion\":\"medio kilo de fideos\",\"categoriaID\":\"$CATEGORIA\""
[ -n "$SUBCATEGORIA" ] && CUERPO_PRODUCTO="$CUERPO_PRODUCTO,\"subcategoriaID\":\"$SUBCATEGORIA\""
[ -n "${IDENTIFICADOR:-}" ] && CUERPO_PRODUCTO="$CUERPO_PRODUCTO,\"identificadorID\":\"$IDENTIFICADOR\""
CUERPO_PRODUCTO="$CUERPO_PRODUCTO}"
req POST "$URL_DONACIONES/productos" "$CUERPO_PRODUCTO"
PRODUCTO=$(campo '.id')
if [ -n "$PRODUCTO" ] && [ "$PRODUCTO" != "null" ]; then
  ok "producto creado: $PRODUCTO"; guardar PRODUCTO "$PRODUCTO"
else
  falla "no se pudo crear el producto: sin el no corre ningun flujo"; resumen; exit 1
fi

# ============================================================ DONADORES
titulo "2/4  DONADORES Y ENTIDADES: donadores, entidad y necesidades"

crear_donador() {
  local etiqueta="$1"
  req POST "$URL_DONADORES/donadores" \
    "{\"nombre\":\"$PREFIJO-$etiqueta\",\"apellido\":\"Prueba\",\"edad\":30,\"email\":\"$PREFIJO-$etiqueta-$SELLO@test.local\",\"nroDocumento\":\"$SELLO\",\"domicilio\":\"Calle de prueba 100\"}"
  campo '.id'
}

sumar_quejas() {
  local donador="$1" cantidad="$2" i=1
  while [ "$i" -le "$cantidad" ]; do
    curl -sS -m "$TIMEOUT" -o /dev/null -X POST -H 'Content-Type: application/json' \
      -d "{\"donacionID\":\"seed\",\"donadorID\":\"$donador\",\"fecha\":\"$(date +%Y-%m-%d)\",\"descripcion\":\"queja de seed $i\"}" \
      "$URL_DONADORES/donadores/$donador/quejas"
    i=$((i + 1))
  done
  req GET "$URL_DONADORES/donadores/$donador"
  campo '.estado'
}

paso "Donador limpio (para los flujos que necesitan donar)"
DONADOR_OK=$(crear_donador "donador-ok")
if [ -n "$DONADOR_OK" ] && [ "$DONADOR_OK" != "null" ]; then
  ok "donador creado: $DONADOR_OK"
  guardar DONADOR_OK "$DONADOR_OK"
  req GET "$URL_DONADORES/donadores/$DONADOR_OK"
  verificar "estado inicial del donador" "VERIFICADO" "$(campo '.estado')"
else
  falla "no se pudo crear el donador"; resumen; exit 1
fi

paso "Donador con 5 quejas (deberia quedar SOSPECHOSO)"
DONADOR_SOSPECHOSO=$(crear_donador "donador-sospechoso")
if [ -n "$DONADOR_SOSPECHOSO" ] && [ "$DONADOR_SOSPECHOSO" != "null" ]; then
  guardar DONADOR_SOSPECHOSO "$DONADOR_SOSPECHOSO"
  detalle "cargando 5 quejas..."
  verificar "estado con 5 quejas" "SOSPECHOSO" "$(sumar_quejas "$DONADOR_SOSPECHOSO" 5)"
else
  aviso "no se pudo crear el donador sospechoso"
fi

paso "Donador con 9 quejas (para demostrar el baneo sumando una mas en vivo)"
DONADOR_CASI_BANEADO=$(crear_donador "donador-9-quejas")
if [ -n "$DONADOR_CASI_BANEADO" ] && [ "$DONADOR_CASI_BANEADO" != "null" ]; then
  guardar DONADOR_CASI_BANEADO "$DONADOR_CASI_BANEADO"
  detalle "cargando 9 quejas..."
  estado9=$(sumar_quejas "$DONADOR_CASI_BANEADO" 9)
  verificar "estado con 9 quejas (todavia no baneado)" "SOSPECHOSO" "$estado9"
  detalle "en la demo: sumale la queja 10 y tiene que pasar a BANEADO"
else
  aviso "no se pudo crear el donador de 9 quejas"
fi

paso "Entidad benefica"
req POST "$URL_DONADORES/entidades" \
  "{\"razonSocial\":\"$PREFIJO-Comedor-$SELLO\",\"domicilio\":\"Av. de prueba 742\",\"telefono\":\"1140000000\",\"correo\":\"$PREFIJO-$SELLO@comedor.test\"}"
ENTIDAD=$(campo '.id')
if [ -n "$ENTIDAD" ] && [ "$ENTIDAD" != "null" ]; then
  ok "entidad creada: $ENTIDAD"; guardar ENTIDAD "$ENTIDAD"
else
  falla "no se pudo crear la entidad"; resumen; exit 1
fi

paso "Necesidad EXTRAORDINARIA de 100 unidades"
detalle "admite satisfaccion parcial: sirve para el flujo de registrar donacion"
req POST "$URL_DONADORES/necesidades" \
  "{\"entidadID\":\"$ENTIDAD\",\"productoSolicitadoID\":\"$PRODUCTO\",\"descripcion\":\"$PREFIJO necesidad extraordinaria\",\"cantidadObjetivo\":100,\"nivelDeUrgencia\":9,\"tipo\":\"EXTRAORDINARIA\"}"
NECESIDAD_EXTRA=$(campo '.id')
[ -n "$NECESIDAD_EXTRA" ] && [ "$NECESIDAD_EXTRA" != "null" ] \
  && { ok "necesidad extraordinaria: $NECESIDAD_EXTRA"; guardar NECESIDAD_EXTRA "$NECESIDAD_EXTRA"; } \
  || falla "no se pudo crear la necesidad extraordinaria"

paso "Necesidad RECURRENTE de 50 unidades"
detalle "no admite parcial: sirve para mostrar la bifurcacion del matchmaking"
req POST "$URL_DONADORES/necesidades" \
  "{\"entidadID\":\"$ENTIDAD\",\"productoSolicitadoID\":\"$PRODUCTO\",\"descripcion\":\"$PREFIJO necesidad recurrente\",\"cantidadObjetivo\":50,\"nivelDeUrgencia\":5,\"tipo\":\"RECURRENTE\"}"
NECESIDAD_RECURRENTE=$(campo '.id')
[ -n "$NECESIDAD_RECURRENTE" ] && [ "$NECESIDAD_RECURRENTE" != "null" ] \
  && { ok "necesidad recurrente: $NECESIDAD_RECURRENTE"; guardar NECESIDAD_RECURRENTE "$NECESIDAD_RECURRENTE"; } \
  || aviso "no se pudo crear la necesidad recurrente"

# ============================================================ LOGISTICA
titulo "3/4  LOGISTICA: deposito con algoritmo de matchmaking"

paso "Deposito"
req POST "$URL_LOGISTICA/depositos" \
  "{\"nombre\":\"$PREFIJO-Deposito-$SELLO\",\"direccion\":\"Av. de prueba 3000\",\"capacidadMaxima\":1000}"
DEPOSITO=$(campo '.id')
if [ -n "$DEPOSITO" ] && [ "$DEPOSITO" != "null" ]; then
  ok "deposito creado: $DEPOSITO"; guardar DEPOSITO "$DEPOSITO"
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
  verificar "el algoritmo arranca en null, como pide el enunciado" "null" "$(campo '.algoritmo')"

  paso "Seteando el algoritmo SUB_ATENDIDOS"
  req PATCH "$URL_LOGISTICA/depositos/$DEPOSITO/algoritmo" '{"algoritmo":"SUB_ATENDIDOS"}'
  req GET "$URL_LOGISTICA/depositos/$DEPOSITO"
  verificar "algoritmo seteado" "SUB_ATENDIDOS" "$(campo '.algoritmo')"
else
  falla "no se pudo crear el deposito"; resumen; exit 1
fi

# ============================================================ INCENTIVOS
titulo "4/4  INCENTIVOS: insignia y mision"

paso "Insignia"
req POST "$URL_INCENTIVOS/insignias" \
  "{\"nombre\":\"$PREFIJO-Insignia-$SELLO\",\"descripcion\":\"insignia de prueba\"}"
INSIGNIA=$(campo '.id')
[ -n "$INSIGNIA" ] && [ "$INSIGNIA" != "null" ] \
  && { ok "insignia creada: $INSIGNIA"; guardar INSIGNIA "$INSIGNIA"; } \
  || aviso "no se pudo crear la insignia"

paso "Mision COMPLETITUD (OCASIONAL -> COLABORADOR)"
detalle "se completa donando en 3 categorias distintas"
req POST "$URL_INCENTIVOS/misiones" \
  "{\"nombre\":\"$PREFIJO-Completitud-$SELLO\",\"insigniaID\":\"${INSIGNIA:-}\",\"categoriaInicio\":\"OCASIONAL\",\"categoriaFin\":\"COLABORADOR\",\"tipo\":\"COMPLETITUD\"}"
MISION=$(campo '.id')
[ -n "$MISION" ] && [ "$MISION" != "null" ] \
  && { ok "mision creada: $MISION"; guardar MISION "$MISION"; } \
  || aviso "no se pudo crear la mision"

# ============================================================ CIERRE
titulo "IDs GUARDADOS EN .estado"
if [ -f "$ARCHIVO_ESTADO" ]; then
  sed 's/^/  /' "$ARCHIVO_ESTADO"
fi

echo ""
echo "Listo. Ahora podes correr los flujos:"
echo "  ./10-flujo-registrar-donacion.sh"
echo "  ./11-flujo-reportar-entrega.sh"
echo "  ./12-flujo-procesar-donador.sh"
echo "  ./13-flujo-estadisticas.sh"
echo "  ./14-flujo-queja-baneo.sh"

resumen
