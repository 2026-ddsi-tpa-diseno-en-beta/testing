# Guía rápida

Qué ejecutar, cómo y desde dónde. Para el detalle de cada script, ver el [README](README.md).

---

## Antes de empezar (una sola vez)

```bash
cd testing
cp config.sh.example config.sh
chmod +x *.sh
```

Solo hace falta `bash` y `curl`. Nada más que instalar.

---

## El día de la presentación

### Terminal 1 — dejarla abierta todo el tiempo

```bash
./keepalive.sh
```

Le pega a los 4 servicios cada 3 minutos para que Render no los duerma. **No cierres esta
terminal.** Si un servicio se duerme, despertarlo tarda más de 90 segundos y parece que el
sistema no funciona.

Arrancala **20 minutos antes** de presentar.

### Terminal 2 — el Worker de Logística

Sin un Worker consumiendo la cola, ninguna donación llega a asignarse. El enunciado permite
correrlo local durante la entrega.

```bash
cd ../Componente_Logistica
mvn -q clean package -DskipTests

SPRING_PROFILES_ACTIVE=worker \
RABBITMQ_URL=<la de CloudAMQP> \
DONADORES_URL=https://entrega-2-lolasimone.onrender.com \
LOGISTICA_API_URL=https://donatrack-api-logistica-diseno-en-beta.onrender.com \
java -jar target/*-worker.jar
```

Dejala corriendo también.

### Terminal 3 — el bot de Telegram

```bash
cd ../telegramBot/untitled
# la primera vez: completar telegram.bot.token en src/main/resources/application.properties
mvn -q compile
mvn dependency:build-classpath -Dmdep.outputFile=/tmp/cp.txt
java -cp "target/classes:$(cat /tmp/cp.txt)" ar.edu.utn.dds.bot.BotApplication
```

Tiene que decir `DonaTrack Telegram Bot iniciado.`

> **Solo una persona puede correr el bot a la vez.** Si otro lo tiene levantado con el mismo
> token, Telegram devuelve 409 y el bot arranca pero no responde ningún mensaje. Confirmen por
> el grupo que no quedó prendido en la máquina de nadie.

### Terminal 4 — preparar los datos

```bash
cd testing
./00-salud.sh    # confirmar que los 4 estén UP
./01-seed.sh     # cargar las precondiciones
```

Listo para presentar.

---

## Verificar que todo funciona

### Todo de una

```bash
./correr-todo.sh 2>&1 | tee corrida.log
```

Sale con código `0` si no hubo fallas. El detalle de cada paso queda en `corrida.log`.

### De a uno

```bash
./00-salud.sh                          # los 4 servicios
./01-seed.sh                           # precondiciones

# los 5 flujos de la demo
./10-flujo-registrar-donacion.sh
./11-flujo-reportar-entrega.sh
./12-flujo-procesar-donador.sh
./13-flujo-estadisticas.sh
./23-flujo-cumplir-mision-insignia.sh
./14-flujo-queja-baneo.sh

# los flujos nuevos de la Entrega 4
./20-flujo-necesidad-y-stock.sh
./21-flujo-parcialidad-por-tipo.sh
./22-contratos-del-bot.sh
```

---

## Guion de defensa: que queremos probar

La demo no consiste en tirar comandos al azar: cada script muestra una regla de negocio o una
integracion entre modulos. Cuando termines un script, si el profesor pide "mostrame como
quedo", usa `ver-estado.sh`, `ver-donador.sh` o `ver-logistica.sh` para mirar el dato puntual.

Lectura comun de la salida:

| Marca | Como explicarlo |
|---|---|
| `[OK]` | La validacion dio lo esperado. |
| `[AVISO]` | El sistema respondio, pero hay algo para explicar o mirar. No necesariamente bloquea la demo. |
| `[FALLA]` | El comportamiento no coincide con lo esperado. No seguir vendiendolo como verde: explicar que detecto el script. |
| `GET/POST/PUT/DELETE ... -> HTTP N` | Es la llamada real que se hizo al servicio. Sirve para mostrar que no es un mock. |

### Orden recomendado para una demo verde

```bash
./00-salud.sh
./01-seed.sh
./10-flujo-registrar-donacion.sh
./ver-estado.sh donacion --esperado INGRESADA
./ver-logistica.sh --detalle

./11-flujo-reportar-entrega.sh
./ver-estado.sh asignacion --esperado COMPLETADA
./ver-estado.sh donacion --esperado ACEPTADA

./12-flujo-procesar-donador.sh
./13-flujo-estadisticas.sh
./23-flujo-cumplir-mision-insignia.sh
./ver-donador.sh mision --detalle
./ver-donador.sh ok --detalle

./14-flujo-queja-baneo.sh
./ver-estado.sh donacion --esperado CONQUEJA
./ver-donador.sh ok --detalle

./20-flujo-necesidad-y-stock.sh
./ver-logistica.sh --detalle

./22-contratos-del-bot.sh
```

`21-flujo-parcialidad-por-tipo.sh` es muy bueno como prueba de Entrega 4, pero correlo en demo
solo si el comportamiento ya esta corregido. Lo esperado es: `EXTRAORDINARIA` acepta parcial y
`RECURRENTE` no acepta parcial. Si falla, el script esta mostrando un bug real.

### Preparacion de datos

| Script | Que probamos | Que deberia pasar | Que mostrar despues |
|---|---|---|---|
| `./00-salud.sh` | Que los servicios y workers estan despiertos. | Donaciones, Donadores, Incentivos, Logistica y workers deben aparecer `UP`. | Si tarda mucho, explicar Render/cold start. |
| `./01-seed.sh` | Que podemos precargar una historia consistente para la demo. | Crea categoria, subcategoria, producto, donadores, entidad, necesidades, deposito, insignia y mision. Guarda IDs en `.estado`. | `./estado.sh --ids` para mostrar los IDs que van a usar los demas scripts. |
| `./estado.sh --detalle` | Foto general del sistema. | No modifica nada; solo hace GETs. | Sirve si preguntan "con que datos estan probando". |

Que explicar: "El seed deja un escenario conocido. No es magia del script: despues cada flujo
usa esos IDs y consulta servicios reales".

### Que carga exactamente el seed

`./01-seed.sh` crea datos nuevos en cada corrida, con nombres reconocibles y un sello horario
tipo `MMDD-HHMMSS`. Al final guarda los IDs en `.estado`, asi que se pueden mostrar rapido con:

```bash
./estado.sh --ids
```

| Modulo | Dato que carga | Alias en `.estado` | Para que sirve en la defensa |
|---|---|---|---|
| Donaciones | Categoria raiz `Alimentos no perecederos <sello>` | `CATEGORIA` | Base para crear el producto de prueba. |
| Donaciones | Subcategoria `Pastas secas <sello>` | `SUBCATEGORIA` | Muestra jerarquia de categorias y unidad minima de asignacion. |
| Donaciones | Identificador `CODIGODEBARRAS` | `IDENTIFICADOR` | Prueba la validacion de productos con codigo de barras. |
| Donaciones | Producto `Fideos tirabuzon La Familiar` | `PRODUCTO` | Producto comun que usan donaciones, necesidades y stock. |
| Donadores | Donador limpio `Carla Medina` | `DONADOR_OK` | Donador principal para registrar donaciones y consultar estadisticas. |
| Donadores | Donador con 5 quejas `Bruno Sosa` | `DONADOR_SOSPECHOSO` | Demuestra el umbral `SOSPECHOSO`. |
| Donadores | Donador con 9 quejas `Elena Rivas` | `DONADOR_CASI_BANEADO` | Queda a una queja de pasar a `BANEADO`. |
| Donadores y Entidades | Entidad `Comedor Comunitario Los Pinos <sello>` | `ENTIDAD` | Receptora de las necesidades de la demo. |
| Donadores y Entidades | Necesidad `EXTRAORDINARIA` de 100 unidades | `NECESIDAD_EXTRA` | Acepta satisfaccion parcial; sirve para registrar donaciones y matchmaking. |
| Donadores y Entidades | Necesidad `RECURRENTE` de 50 unidades | `NECESIDAD_RECURRENTE` | No deberia aceptar parcial; sirve para contrastar reglas por tipo. |
| Logistica | Deposito `Deposito Barracas Central <sello>`, capacidad 1000 | `DEPOSITO` | Lugar donde entran paquetes y se calcula stock/asignacion. |
| Logistica | Algoritmo del deposito en `SUB_ATENDIDOS` | mismo `DEPOSITO` | Primero verifica que arranca `null`, despues lo deja configurado. |
| Incentivos | Insignia `Aliado de Comedores <sello>` | `INSIGNIA` | Recompensa asociada a la mision creada. |
| Incentivos | Mision `COMPLETITUD`, de `OCASIONAL` a `COLABORADOR` | `MISION` | Se completa donando en 3 categorias distintas. |

Frase corta para el profe:

```text
El seed cargo una historia integrada: producto y categorias en Donaciones; tres donadores con
distintos estados de quejas; una entidad con necesidades extraordinaria y recurrente; un
deposito con algoritmo de matchmaking; y una insignia con mision en Incentivos. Los IDs quedan
en .estado y todos los flujos posteriores usan esos datos reales.
```

### Flujo 1: registrar una donacion

```bash
./10-flujo-registrar-donacion.sh
```

| Punto | Esperable |
|---|---|
| Donadores | `puede-donar` responde `true` para el donador. |
| Donaciones | La donacion nace en `INGRESADA`. |
| Logistica | Se crea un paquete en el deposito. |
| Worker | Consume la cola y crea una asignacion si hay necesidad para ese producto. |
| Estado final | La donacion sigue `INGRESADA` hasta que se reporte la entrega. |

Mostrar despues:

```bash
./ver-estado.sh donacion --esperado INGRESADA
./ver-logistica.sh --detalle
./ver-estado.sh asignacion
```

Si el profesor pregunta "cuantas donaciones tiene ese donador":

```bash
./ver-donador.sh ok --detalle
```

Si pregunta "puedo donar otra cantidad":

```bash
./donar.sh --cantidad 15
./donar.sh --cantidad 15 --sin-esperar
```

Que explicar: "`donar.sh` es la version flexible del flujo 1. El flujo 10 es el caso guionado;
`donar.sh` me deja cambiar cantidad, donador, producto o deposito".

### Flujo 2: reportar una entrega

```bash
./11-flujo-reportar-entrega.sh
```

| Punto | Esperable |
|---|---|
| Logistica | La asignacion pasa de `ASIGNADA` a `COMPLETADA`. |
| Donadores | Logistica informa que la necesidad fue satisfecha. |
| Donaciones | La donacion pasa de `INGRESADA` a `ACEPTADA`. |
| Historial | Debe verse la trazabilidad de estados. |

Mostrar despues:

```bash
./ver-estado.sh asignacion --esperado COMPLETADA
./ver-estado.sh donacion --esperado ACEPTADA
./ver-estado.sh necesidad extra
```

Si el profesor pregunta "donde veo el historial":

```bash
./ver-estado.sh donacion --json
```

Que explicar: "La donacion no queda aceptada cuando se registra, queda aceptada recien cuando
Logistica confirma la entrega".

### Flujo 3, 4 y 23: incentivos, misiones e insignias

```bash
./12-flujo-procesar-donador.sh
./13-flujo-estadisticas.sh
./23-flujo-cumplir-mision-insignia.sh
```

| Script | Que probamos | Esperable |
|---|---|---|
| `12-flujo-procesar-donador.sh` | Que se puede asignar una mision, verla en curso, procesar un donador y que el progreso sea por donador. | La mision queda en curso si todavia no cumple la regla; el donador de control no se afecta. |
| `13-flujo-estadisticas.sh` | Que Donadores consulta a Incentivos para mostrar mision e insignias en `/estadisticas`. | Lo que ve Donadores coincide con la fuente de verdad de Incentivos. |
| `23-flujo-cumplir-mision-insignia.sh` | Que una mision `COMPLETITUD` se cumple y otorga su insignia automaticamente. | Despues de procesar, la insignia aparece en Incentivos y tambien en `/estadisticas`. |

Mostrar despues:

```bash
./ver-donador.sh ok --detalle
./ver-donador.sh mision --detalle
./ver-estado.sh donador ok
```

Si el profesor pregunta "y si quiero otro donador":

```bash
./crear-donador.sh --nombre Demo --apellido Profe --edad 30 --guardar-como DONADOR_DEMO
./13-flujo-estadisticas.sh "$DONADOR_DEMO"
./ver-donador.sh demo --detalle
```

Que explicar: "Donadores muestra el perfil, pero las insignias/misiones vienen integradas
desde Incentivos".

#### Que esta cubierto de misiones e insignias

Respuesta corta para el profesor: **si, esta cubierto el caso de otorgar una insignia por
cumplir una mision**, y el script para mostrarlo es `23-flujo-cumplir-mision-insignia.sh`.

| Caso | Donde se cubre | Como defenderlo |
|---|---|---|
| Crear una insignia y una mision | `./01-seed.sh` y `./crear-mision.sh` | "La insignia existe como recompensa y la mision referencia esa insignia." |
| Asignar una mision a un donador | `./12-flujo-procesar-donador.sh` y `./23-flujo-cumplir-mision-insignia.sh` | "Incentivos recibe la mision y despues la devuelve como mision en curso." |
| Procesar un donador | `./12-flujo-procesar-donador.sh` | "Se llama a `POST /procesamiento/{donadorID}`; Incentivos lee el historial de Donaciones." |
| Evitar progreso compartido entre donadores | `./12-flujo-procesar-donador.sh` | "Asigno la misma mision a dos donadores, proceso solo uno y verifico que el otro no cambie." |
| Cumplir una mision y ganar insignia | `./23-flujo-cumplir-mision-insignia.sh` | "Creo 3 donaciones en 3 categorias distintas, proceso el donador y aparece la insignia." |
| Mostrar insignias desde Donadores | `./13-flujo-estadisticas.sh` y `./23-flujo-cumplir-mision-insignia.sh` | "Donadores no inventa las insignias: consulta a Incentivos y las expone en `/estadisticas`." |
| Crear cualquiera de las 4 misiones del enunciado | `./crear-mision.sh --tipo <tipo>` | "El helper conoce tipo, categoria inicial/final e insignia asociada." |

Lo importante: `12` prueba **procesamiento y aislamiento del progreso**, pero no necesariamente
completa la mision del seed porque `COMPLETITUD` necesita 3 categorias distintas. Para mostrar
la insignia ganada por una mision cumplida, usar `23`.

Reglas implementadas por tipo de mision:

| Tipo | Condicion que evalua Incentivos | Receta de demo |
|---|---|---|
| `COMPLETITUD` | Donaciones en 3 categorias distintas. | `./23-flujo-cumplir-mision-insignia.sh` |
| `DONACIONES_ASCENDENTES` | Ultimas 5 donaciones con cantidades crecientes. | `./crear-mision.sh --tipo DONACIONES_ASCENDENTES --asignar-a <donadorID>` y despues `./donar.sh --veces 5 --cantidad 10 --incremental`. |
| `DONACIONES_EXITOSAS` | 20 donaciones en estado `ACEPTADA`. | Requiere registrar y reportar entregas; no es el caso corto para una demo en vivo. |
| `REVOLUCION_DONADORA` | Mas de 10 donaciones de mas de 50 unidades. | `./crear-mision.sh --tipo REVOLUCION_DONADORA --asignar-a <donadorID>` y `./donar.sh --veces 11 --cantidad 60`. |

Comandos para mostrar el caso completo:

```bash
./23-flujo-cumplir-mision-insignia.sh
./ver-donador.sh mision --detalle
```

Que explicar: "Aca no estoy asignando la insignia a mano. La insignia se crea como recompensa
de la mision; el donador cumple la regla de COMPLETITUD; y recien cuando ejecuto
`POST /procesamiento/{donadorID}`, Incentivos detecta el cumplimiento, marca la mision como
completada y agrega la insignia al donador".

### Flujo 5: queja y estado del donador

```bash
./14-flujo-queja-baneo.sh
```

| Punto | Esperable |
|---|---|
| Precondicion | La donacion debe estar `ACEPTADA`. |
| Donaciones | Al registrar la queja, la donacion pasa a `CONQUEJA`. |
| Donadores | La queja se propaga al donador. |
| Historial | Debe verse `INGRESADA -> ACEPTADA -> CONQUEJA`. |

Mostrar despues:

```bash
./ver-estado.sh donacion --esperado CONQUEJA
./ver-donador.sh ok --detalle
```

Si el profesor pide cargar una queja adicional:

```bash
./cargar-quejas.sh ok --cantidad 1
./ver-donador.sh ok --detalle
```

Si quiere ver los umbrales sin tocar el donador principal:

```bash
./crear-donador.sh --nombre Umbral --apellido Demo --edad 30 --guardar-como DONADOR_MANUAL
./cargar-quejas.sh manual --cantidad 4
./ver-donador.sh manual
./cargar-quejas.sh manual --cantidad 1
./ver-donador.sh manual
./cargar-quejas.sh manual --cantidad 5
./ver-donador.sh manual
```

Esperable:

| Quejas | Estado |
|---|---|
| 0 a 4 | `VERIFICADO` |
| 5 a 9 | `SOSPECHOSO` |
| 10 o mas | `BANEADO` |

Si quiere que la queja entre por Donaciones sobre una donacion real:

```bash
./cargar-quejas.sh --via-donaciones --donacion "$DONACION"
./ver-estado.sh donacion --esperado CONQUEJA
```

### Entrega 4: necesidad contra stock

```bash
./20-flujo-necesidad-y-stock.sh
```

| Punto | Esperable |
|---|---|
| Validacion de producto | Donadores rechaza productos inexistentes consultando Donaciones. |
| Donacion sin necesidad | Las unidades quedan como stock en Logistica. |
| Alta de necesidad | Donadores consulta stock y pide asignacion inmediata. |
| Resultado | Si habia 10 y se piden 9, queda stock 1 y aparece una asignacion nueva. |

Mostrar despues:

```bash
./ver-logistica.sh --detalle
./ver-estado.sh stock "$PROD_STOCK" --esperado 1
./ver-estado.sh necesidad stock
```

Si el profesor pide cambiar la cantidad objetivo:

```bash
./modificar-necesidad.sh stock --cantidad 12
./ver-estado.sh necesidad stock
```

Si pide crear otra necesidad manual:

```bash
./crear-necesidad.sh --producto "$PRODUCTO" --cantidad 25 --tipo EXTRAORDINARIA --guardar-como NECESIDAD_DEMO
./ver-estado.sh necesidad "$NECESIDAD_DEMO"
```

Que explicar: "Este flujo demuestra la novedad de Entrega 4: al crear una necesidad, no espera
una donacion futura; primero mira stock disponible en Logistica".

### Entrega 4: parcialidad por tipo de necesidad

```bash
./21-flujo-parcialidad-por-tipo.sh 5
```

| Caso | Esperable |
|---|---|
| `EXTRAORDINARIA`, stock menor al objetivo | Acepta asignacion parcial. |
| `RECURRENTE`, stock menor al objetivo | No acepta parcial; espera poder cubrir en una unica entrega. |

Mostrar despues:

```bash
./ver-logistica.sh --detalle
```

Si falla, como explicarlo: "El script esta probando una regla especifica del enunciado. Si la
recurrente recibe parcial, no fallo el script: detecto que ambos tipos se estan tratando igual".

### Entrega 4: contratos del bot

```bash
./22-contratos-del-bot.sh
```

| Punto | Esperable |
|---|---|
| Donador | Puede registrarse, consultar estadisticas y consultar donadores. |
| Admin | Puede crear/editar/consultar entidad. |
| Necesidades | Puede crear, consultar, modificar y borrar necesidades. |
| Salida | Debe terminar con `FALLAS: 0`. Puede tener `AVISOS` por formato de Telegram o campos no editables. |

Si el profesor pregunta "esto prueba Telegram?":

```text
No prueba Telegram como interfaz. Prueba los contratos HTTP que el bot consume.
El parseo de comandos y permisos del bot se validan levantando el bot.
```

Si pide ver el bot real:

```bash
cd ../telegramBot/untitled
mvn -q compile
mvn dependency:build-classpath -Dmdep.outputFile=/tmp/cp.txt
java -cp "target/classes:$(cat /tmp/cp.txt)" ar.edu.utn.dds.bot.BotApplication
```

### Logistica en vivo

Usar cuando pregunten "donde quedo el paquete", "cuanto stock hay", "que algoritmo se usa" o
"como se si el worker esta vivo".

```bash
./ver-logistica.sh --detalle
./ver-logistica.sh --producto "$PRODUCTO"
./ver-logistica.sh --paquete "$PAQUETE"
./ver-logistica.sh --asignacion "$ASIGNACION"
```

Si pide cambiar el algoritmo:

```bash
./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE
./ver-logistica.sh --detalle
./modificar-deposito.sh --algoritmo SUB_ATENDIDOS
```

Esperable: el deposito muestra el algoritmo nuevo. Si despues donas, el worker usa ese
algoritmo para seleccionar necesidad.

### Cambios seguros durante la defensa

Si vas a probar umbrales, primero crea un donador manual para no tocar el donador principal:

```bash
./crear-donador.sh --nombre Manual --apellido Quejas --edad 30 --guardar-como DONADOR_MANUAL
```

| Si el profesor pide... | Comando |
|---|---|
| "Mostrame el estado de esta donacion" | `./ver-estado.sh donacion <id>` |
| "Mostrame que cambio a ACEPTADA" | `./ver-estado.sh donacion --esperado ACEPTADA` |
| "Cuantas donaciones tiene este donador" | `./ver-donador.sh <id> --detalle` |
| "Cargale una queja" | `./cargar-quejas.sh <id> --cantidad 1` |
| "Quiero ver que llegue a sospechoso" | `./cargar-quejas.sh manual --cantidad 5` y despues `./ver-donador.sh manual` |
| "Quiero ver que llegue a baneado" | `./cargar-quejas.sh manual --cantidad 10` y despues `./ver-donador.sh manual` |
| "Cambia cantidad de una necesidad" | `./modificar-necesidad.sh extra --cantidad 45` |
| "Cambia descripcion de una necesidad" | `./modificar-necesidad.sh extra --descripcion "Cambio pedido por el profesor"` |
| "Cambia urgencia" | `./modificar-necesidad.sh extra --urgencia 10` |
| "Cambia algoritmo de deposito" | `./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE` |
| "Mostrame stock de un producto" | `./ver-estado.sh stock <productoID>` |
| "Mostrame todo Logistica" | `./ver-logistica.sh --detalle` |

Para ensayar sin tocar datos, agregar `--dry-run` en los scripts de escritura:

```bash
./cargar-quejas.sh manual --cantidad 1 --dry-run
./modificar-necesidad.sh extra --cantidad 45 --dry-run
./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE --dry-run
```

### Casos nuevos para preguntas en vivo

Estos son los casos agregados para cuando el profesor pida cambiar o consultar algo puntual
durante la defensa.

#### 1. Agregar una queja a un donador

Caso simple, directo contra Donadores y Entidades:

```bash
./cargar-quejas.sh ok --cantidad 1
./ver-donador.sh ok --detalle
```

Con un ID especifico:

```bash
./cargar-quejas.sh <donadorID> --cantidad 1
./ver-donador.sh <donadorID> --detalle
```

Con texto personalizado:

```bash
./cargar-quejas.sh <donadorID> --cantidad 1 --descripcion "Producto en mal estado"
./ver-donador.sh <donadorID> --detalle
```

Ensayo sin escribir:

```bash
./cargar-quejas.sh <donadorID> --cantidad 1 --dry-run
```

Que deberia verse:

| Momento | Esperable |
|---|---|
| Antes | Muestra cantidad de quejas, estado y `puede-donar`. |
| Accion | Hace `POST /donadores/{id}/quejas`. |
| Despues | La cantidad de quejas sube. El estado puede cambiar segun el umbral. |

Que explicar: "Aca no estoy creando una donacion nueva. Estoy cargando una queja al historial
del donador para demostrar como cambia su reputacion".

#### 2. Agregar una queja a una donacion aceptada

Este caso entra por Donaciones y despues se propaga a Donadores.

```bash
./cargar-quejas.sh --via-donaciones --donacion "$DONACION"
./ver-estado.sh donacion --esperado CONQUEJA
./ver-donador.sh ok --detalle
```

Con ID manual:

```bash
./cargar-quejas.sh --via-donaciones --donacion <donacionID>
./ver-estado.sh donacion <donacionID> --esperado CONQUEJA
```

Precondicion: la donacion deberia estar `ACEPTADA`. Si esta `INGRESADA`, primero ejecutar:

```bash
./11-flujo-reportar-entrega.sh
```

Que deberia verse:

| Modulo | Esperable |
|---|---|
| Donaciones | La donacion pasa a `CONQUEJA`. |
| Donadores | El donador suma una queja. |
| Historial | Se ve la trazabilidad de la donacion. |

#### 3. Mostrar cantidad de donaciones de un donador

```bash
./ver-donador.sh ok --detalle
```

Con ID manual:

```bash
./ver-donador.sh <donadorID> --detalle
```

Que deberia verse:

| Campo | Que muestra |
|---|---|
| `estado` | Estado actual del donador: `VERIFICADO`, `SOSPECHOSO` o `BANEADO`. |
| `puede-donar` | Si el donador puede donar ahora. |
| `quejas` | Cantidad de quejas registradas. |
| `estadisticas` | Mision actual e insignias. |
| `donaciones` | Total y resumen por estado: `INGRESADA`, `ACEPTADA`, `CONQUEJA`, etc. |

Que explicar: "Esto cruza Donadores con Donaciones: el perfil vive en Donadores, pero las
donaciones se cuentan consultando el modulo Donaciones".

#### 4. Llevar un donador a SOSPECHOSO o BANEADO

Primero crear un donador manual para no tocar el principal de la demo:

```bash
./crear-donador.sh --nombre Manual --apellido Quejas --edad 30 --guardar-como DONADOR_MANUAL
./ver-donador.sh manual
```

Llevarlo a `SOSPECHOSO`:

```bash
./cargar-quejas.sh manual --cantidad 5
./ver-donador.sh manual
```

Llevarlo a `BANEADO` si ya quedo con 5 quejas y esta `SOSPECHOSO`:

```bash
./cargar-quejas.sh manual --cantidad 5
./ver-donador.sh manual
```

Si queres hacerlo de cero hasta baneado en una sola ejecucion:

```bash
./crear-donador.sh --nombre Baneo --apellido Demo --edad 30 --guardar-como DONADOR_MANUAL
./cargar-quejas.sh manual --cantidad 10
./ver-donador.sh manual
```

Esperable:

| Quejas acumuladas | Estado esperado |
|---|---|
| 0 a 4 | `VERIFICADO` |
| 5 a 9 | `SOSPECHOSO` |
| 10 o mas | `BANEADO` |

Que explicar: "El estado no se pasa a mano. Cambia como consecuencia de la cantidad de quejas".

#### 5. Consultar una donacion puntual

Ultima donacion guardada:

```bash
./ver-estado.sh donacion
```

Esperando un estado concreto:

```bash
./ver-estado.sh donacion --esperado INGRESADA
./ver-estado.sh donacion --esperado ACEPTADA
./ver-estado.sh donacion --esperado CONQUEJA
```

Con ID manual:

```bash
./ver-estado.sh donacion <donacionID>
./ver-estado.sh donacion <donacionID> --json
```

Que deberia verse: ID, donador, producto, cantidad, estado e historial.

#### 6. Crear una donacion flexible

Una donacion con los datos del seed:

```bash
./donar.sh --cantidad 15
```

Elegir donador, producto y deposito:

```bash
./donar.sh --donador <donadorID> --producto <productoID> --deposito <depositoID> --cantidad 20
```

Varias donaciones:

```bash
./donar.sh --veces 3 --cantidad 10
```

Varias donaciones crecientes, util para misiones:

```bash
./donar.sh --veces 5 --cantidad 10 --incremental
```

Que deberia verse:

| Caso | Esperable |
|---|---|
| Hay necesidades del producto | Se crean asignaciones. |
| No hay necesidades del producto | Las unidades quedan en stock. |
| Donador `BANEADO` | El script corta antes de donar. |
| Donador `SOSPECHOSO` | Puede haber rechazos por la regla del 50%. |

#### 7. Ver Logistica en detalle

Estado general:

```bash
./ver-logistica.sh --detalle
```

Stock de un producto:

```bash
./ver-logistica.sh --producto "$PRODUCTO"
./ver-estado.sh stock "$PRODUCTO"
```

Paquete especifico:

```bash
./ver-logistica.sh --paquete "$PAQUETE"
```

Si todavia no existe `PAQUETE`, primero corre `./10-flujo-registrar-donacion.sh`.

Asignacion especifica:

```bash
./ver-logistica.sh --asignacion "$ASIGNACION"
./ver-estado.sh asignacion "$ASIGNACION"
```

Si todavia no existe `ASIGNACION`, primero corre `./10-flujo-registrar-donacion.sh` y espera al
worker.

Que deberia verse:

| Parte | Que muestra |
|---|---|
| Deposito | Capacidad, algoritmo y paquetes actuales. |
| Stock | Cantidad disponible por producto. |
| Asignacion | Paquete, necesidad, cantidad asignada, estado y origen. |
| Cola | Mensajes publicados, consumidos, rechazados y workers vivos. |

Que explicar: "Logistica separa paquetes en deposito, stock disponible y asignaciones. Lo que
ya fue asignado no necesariamente cuenta como stock disponible".

#### 8. Cambiar algoritmo de un deposito

Cambiar a `PRIORIDAD_POR_SCORE`:

```bash
./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE
./ver-logistica.sh --detalle
```

Volver a `SUB_ATENDIDOS`:

```bash
./modificar-deposito.sh --algoritmo SUB_ATENDIDOS
./ver-logistica.sh --detalle
```

Ensayo sin escribir:

```bash
./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE --dry-run
```

Que deberia verse: antes y despues del algoritmo del deposito. El `[OK] algoritmo aplicado`
confirma que el cambio quedo persistido.

#### 9. Modificar una necesidad

Cambiar cantidad:

```bash
./modificar-necesidad.sh extra --cantidad 45
./ver-estado.sh necesidad extra
```

Cambiar descripcion:

```bash
./modificar-necesidad.sh extra --descripcion "Cambio pedido por el profesor"
./ver-estado.sh necesidad extra
```

Cambiar urgencia:

```bash
./modificar-necesidad.sh extra --urgencia 10
./ver-estado.sh necesidad extra
```

Cambiar tipo:

```bash
./modificar-necesidad.sh extra --tipo RECURRENTE
./ver-estado.sh necesidad extra
```

Con ID manual:

```bash
./modificar-necesidad.sh <necesidadID> --cantidad 30
./ver-estado.sh necesidad <necesidadID>
```

Ensayo sin escribir:

```bash
./modificar-necesidad.sh extra --cantidad 45 --dry-run
```

Que deberia verse: el script muestra valores antes, hace `PUT /necesidades/{id}` y despues
compara campo por campo. Si `nivelDeUrgencia` no cambia, aparece como `[AVISO]` porque la API
actual puede tratarlo como no editable.

#### 10. Crear una necesidad nueva y ver si toma stock

```bash
./crear-necesidad.sh --producto "$PRODUCTO" --cantidad 25 --tipo EXTRAORDINARIA --guardar-como NECESIDAD_DEMO
./ver-estado.sh necesidad "$NECESIDAD_DEMO"
./ver-logistica.sh --producto "$PRODUCTO"
```

Que deberia verse:

| Stock previo | Esperable |
|---|---|
| Stock suficiente | Se asigna inmediatamente. |
| Stock parcial y necesidad `EXTRAORDINARIA` | Puede asignarse parcialmente. |
| Stock parcial y necesidad `RECURRENTE` | No deberia asignarse parcialmente. |
| Sin stock | Queda como necesidad insatisfecha. |

#### 11. Probar contratos del bot

```bash
./22-contratos-del-bot.sh
```

Que deberia verse: `FALLAS: 0`. Puede haber `[AVISO]` por:

| Aviso | Como explicarlo |
|---|---|
| `/donadores` supera 4096 caracteres | El endpoint funciona; el bot tiene que paginar o resumir si lo muestra por Telegram. |
| `nivelDeUrgencia` no cambia en PUT | La API actual no lo modifica, pero descripcion y cantidad si. |
| DELETE con body vacio | El borrado funciona; el bot debe mostrar confirmacion propia. |

#### 12. Ver IDs disponibles

```bash
./estado.sh --ids
```

Que explicar: "Estos son los IDs guardados en `.estado`. Los aliases como `ok`, `manual`,
`extra`, `stock`, `asignacion` y `paquete` salen de este archivo".

### Frases utiles para explicar que estan viendo

```text
Este script hace requests reales contra los servicios desplegados.
Los IDs vienen de .estado, que los dejo el seed o el flujo anterior.
Primero muestro el estado anterior, despues ejecuto la accion y finalmente leo el estado nuevo.
Los [OK] son validaciones automaticas de negocio, no solo logs.
Si aparece [AVISO], el sistema respondio, pero hay una condicion que conviene explicar.
```

---

## Ver el estado de todo

```bash
./estado.sh              # resumen de los 4 módulos
./estado.sh --detalle    # además lista las entidades una por una
./estado.sh --ids        # solo los IDs de la última corrida
```

No crea ni modifica nada, son todos GET. Muestra disponibilidad, conteos, donadores agrupados
por estado, el estado de la cola de RabbitMQ y las ejecuciones del cron.

## Ver un estado puntual

```bash
./ver-estado.sh donacion                         # usa DONACION de .estado
./ver-estado.sh donacion --esperado ACEPTADA
./ver-estado.sh donador ok --esperado VERIFICADO
./ver-estado.sh donador sospechoso --esperado SOSPECHOSO
./ver-estado.sh asignacion --esperado COMPLETADA
./ver-estado.sh necesidad extra
./ver-estado.sh stock "$PRODUCTO" --esperado 1
```

Tambien acepta IDs manuales:

```bash
./ver-estado.sh donacion 37 --esperado CONQUEJA
./ver-estado.sh donador 94adf56f-e01e-4b0e-8232-8da0845d61fc --json
```

Este script sirve para una demo guiada: corres un flujo, despues corres una lectura puntual y
mostras exactamente que campo cambio.

## Responder preguntas del profesor

**Cuantas donaciones tiene este donador y en que estado estan**

```bash
./ver-donador.sh ok --detalle
./ver-donador.sh <donadorID> --detalle
```

**Por que el donador esta VERIFICADO, SOSPECHOSO o BANEADO**

```bash
./ver-donador.sh ok
./cargar-quejas.sh manual --cantidad 4
./ver-donador.sh manual
./cargar-quejas.sh manual --cantidad 1
./ver-donador.sh manual
```

Con 1-4 quejas sigue `VERIFICADO`, con 5-9 pasa a `SOSPECHOSO`, con 10 pasa a `BANEADO`.

**Cargar una queja sobre una donacion real aceptada**

```bash
./cargar-quejas.sh --via-donaciones --donacion "$DONACION"
./ver-estado.sh donacion --esperado CONQUEJA
```

**Mostrar que hay en Logistica**

```bash
./ver-logistica.sh --detalle
./ver-logistica.sh --producto "$PRODUCTO"
./ver-logistica.sh --asignacion "$ASIGNACION"
```

**Cambiar valores durante la defensa**

```bash
./modificar-necesidad.sh extra --cantidad 45 --descripcion "Cambio pedido por el profesor"
./modificar-deposito.sh --algoritmo PRIORIDAD_POR_SCORE
./modificar-deposito.sh --algoritmo SUB_ATENDIDOS
```

Todos los scripts que escriben aceptan `--dry-run` para ensayar sin modificar datos.

---

## Crear cosas a mano, de a una

Cada script acepta los datos **por argumento** o **te los pregunta**. Todos tienen `--help`.

```bash
./crear-donador.sh                     # te pregunta cada campo
./crear-donador.sh --nombre Carla --apellido Gomez --edad 29
./crear-donador.sh --quejas 5          # lo crea y lo deja SOSPECHOSO
./crear-donador.sh --quejas 9          # a un paso del baneo, para la demo

./crear-categoria.sh --nombre Alimentos
./crear-categoria.sh --nombre Fideos --padre 12      # como subcategoría

./crear-producto.sh --nombre Mesa --descripcion "una mesa" --categoria 14 --sin-identificador
./crear-producto.sh --nombre Mesa --descripcion "una mesa" --categoria 14 --tipo-identificador QR

./crear-entidad.sh --razon "Comedor Hogwarts"
./crear-necesidad.sh --producto 9 --cantidad 100 --tipo EXTRAORDINARIA
./crear-deposito.sh --algoritmo PRIORIDAD_POR_SCORE
./crear-mision.sh --tipo DONACIONES_ASCENDENTES --asignar-a <donadorID>
```

Cada uno **imprime el ID por stdout**, así que se pueden encadenar:

```bash
CAT=$(./crear-categoria.sh --nombre Mobiliario)
PROD=$(./crear-producto.sh --nombre Mesa --descripcion "una mesa" --categoria "$CAT" --sin-identificador)
./donar.sh --producto "$PROD" --cantidad 40
```

Y guardan el ID en `.estado` para que los demás scripts lo tomen solos. Con `--guardar-como`
elegís el nombre:

```bash
./crear-donador.sh --guardar-como DONADOR_DEMO
./donar.sh --donador "$DONADOR_DEMO"
```

Si no pasas `--guardar-como`, queda guardado como `DONADOR_MANUAL` para no pisar el
`DONADOR_OK` que deja el seed.

### Te avisan antes de que falle

`crear-producto.sh` calcula si lo que pusiste va a pasar la validación, antes de mandar el
request:

```
--> Como queda contra la validacion de identificadores
    nombre 'Silla': 5 letras -> IMPAR, NO sirve para QR
    descripcion: 2 palabras -> NO sirve para CODIGODEBARRAS, hacen falta 3 o mas
```

Y si la categoría que elegiste tiene subcategorías, te lista cuáles y te obliga a elegir una
—porque el módulo lo rechaza— en vez de dejarte comerte un 400 sin explicación.

---

## Donar con los parámetros que quieras

`10-flujo-registrar-donacion.sh` hace un caso fijo y ya probado. `donar.sh` es la versión que
manejás vos:

```bash
./donar.sh                                      # te pregunta y te muestra qué hay
./donar.sh --cantidad 40                        # una donación de 40
./donar.sh --veces 10 --cantidad 5              # 10 donaciones de 5
./donar.sh --veces 5 --cantidad 10 --incremental # 10, 20, 30, 40, 50
./donar.sh --donador abc --producto 9 --deposito 10 --cantidad 60
./donar.sh --veces 3 --cantidad 60 --sin-esperar # sin esperar al worker
```

El `--incremental` sirve para la misión `DONACIONES_ASCENDENTES`, que pide 5 donaciones con
cantidades crecientes.

Antes de donar chequea el estado del donador: si está `BANEADO` corta y te lo dice, y si es
`SOSPECHOSO` te avisa que algunas van a ser rechazadas por el sorteo del 50%.

---

## Recetas para casos concretos

**Mostrar el baneo de un donador**

El seed deja uno con 9 quejas. Sumale la décima y pasa a `BANEADO`:

```bash
./14-flujo-queja-baneo.sh umbrales     # recorre las 10 de un donador nuevo
```

**Mostrar la asignación inmediata desde stock (el caso N-1)**

```bash
./20-flujo-necesidad-y-stock.sh 10
```

Genera stock de 10 unidades y crea una necesidad de 9 del mismo producto, para que se le
asigne directo y quede 1 en stock.

Si todavía no hay Worker corriendo, la donación nunca llega al stock. Para probar el resto de
la cadena igual:

```bash
./20-flujo-necesidad-y-stock.sh 10 --simular-worker
```

**Mostrar que la parcialidad depende del tipo de necesidad**

```bash
./21-flujo-parcialidad-por-tipo.sh 5
```

Genera stock de 5 y pide 15 con cada tipo. `EXTRAORDINARIA` tiene que aceptar la asignación
parcial; `RECURRENTE` no.

**Confirmar que el bot no se va a romper**

```bash
./22-contratos-del-bot.sh
```

Manda los mismos requests que hace el bot y verifica campo por campo que las modificaciones
se apliquen. También calcula con cuántos donadores `/donadores` supera el límite de 4096
caracteres de Telegram.

En la corrida actual, esos limites se informan como `[AVISO]`: el endpoint existe y responde,
pero el bot tiene que formatear o paginar si decide mostrar muchos registros.

**Empezar de cero**

```bash
./99-limpiar.sh    # pide escribir BORRAR
./01-seed.sh
```

> `99-limpiar.sh` vacía las bases enteras, no solo los datos de prueba. Si alguien cargó cosas
> a mano, también se van.

---

## Si algo falla

Los scripts no dicen solo "falló": diagnostican e imprimen el comando para arreglarlo.

**`10-flujo-registrar-donacion.sh` falla** → lee las métricas de RabbitMQ y distingue:

| Métrica | Qué significa | Qué hacer |
|---|---|---|
| `published=0` | el mensaje no salió | revisar `RABBITMQ_URL` y el broker en `/actuator/health` |
| `consumed=0` | nadie lo consumió | no hay Worker escuchando: levantar el de la Terminal 2 |
| `rejected>0` | el Worker falló | casi siempre `LOGISTICA_API_URL` mal seteada; mirar los logs en Render |

**`11-flujo-reportar-entrega.sh` falla** → depende del flujo 1. Sin asignación no hay nada que
entregar. El script imprime el `curl` para simular el callback del Worker y seguir probando.

**`13-flujo-estadisticas.sh` falla** → compara lo que dice Incentivos contra lo que reporta
Donadores. Si Incentivos tiene insignias y `/estadisticas` devuelve la lista vacía, la
integración `Donadores → Incentivos` no está ocurriendo. Verificar que `URL_INCENTIVOS` esté
configurada y que las rutas coincidan: Incentivos expone `GET /insignias/donador/{id}`, no
`GET /donadores/{id}/insignias`.

**Todo falla con timeout** → los servicios estaban dormidos. Corré `./00-salud.sh` y esperá.

---

## Ajustes por variable de entorno

Sin tocar `config.sh`:

```bash
TIMEOUT=300 ./00-salud.sh                      # más paciencia con los cold starts
ESPERA=60 ./10-flujo-registrar-donacion.sh     # esperar más al worker
PREFIJO=DEMO ./01-seed.sh                      # otro prefijo para los datos
./keepalive.sh 120                             # pingear cada 2 minutos
./10-flujo-registrar-donacion.sh 25            # donar 25 unidades
./13-flujo-estadisticas.sh <donadorID>         # otro donador
```

---

## Qué cubre y qué no

| Escenario | Script | Estado |
|---|---|---|
| Registrar donación con matchmaking | `10` | necesita Worker |
| Reportar entrega (los 3 efectos en orden) | `11` | depende del `10` |
| Procesar donador y aislar progreso de misiones | `12` | cubierto |
| Estadísticas cruzando Donadores e Incentivos | `13` | cubierto |
| Cumplir misión y otorgar insignia automáticamente | `23` | cubierto para `COMPLETITUD` |
| Queja end-to-end y umbrales de estado | `14` | cubierto |
| Validación del producto contra Donaciones | `20` | cubierto |
| Consulta de stock a Logística | `20` | cubierto |
| Asignación inmediata desde stock (N-1) | `20` | cubierto |
| Distinguir asignación por solicitud vs matchmaking | `20` | cubierto |
| Parcialidad según tipo de necesidad | `21` | cubierto |
| Endpoints que consume el bot | `22` | cubierto |

**Lo que no cubren estos scripts:**

- **El bot en sí.** El `22` verifica los endpoints que el bot consume, no su lógica interna
  (parseo de comandos, gateo por rol, formato de las respuestas). Eso se prueba llamando a
  `BotCommandHandler.handle()` directo, sin Telegram de por medio.
- **El período de las necesidades recurrentes.** El enunciado pide que una recurrente se
  satisfaga una vez por período (semanal o mensual) y vuelva a estar disponible en el
  siguiente. Probarlo requiere manipular el tiempo, así que no está automatizado.
- **Todas las misiones punta a punta.** El `23` cubre el circuito completo con `COMPLETITUD`.
  Las otras misiones tienen recetas, pero `DONACIONES_EXITOSAS` especialmente requiere 20
  donaciones aceptadas y muchas entregas reportadas.
- **Más de un Worker en paralelo.** El enunciado pide soportarlo. Verificarlo requiere levantar
  dos y observar cómo se reparten los mensajes.
- **Las métricas y el dashboard.** Los scripts leen algunos contadores para diagnosticar, pero
  no validan que el dashboard esté completo.
