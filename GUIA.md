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
./14-flujo-queja-baneo.sh

# los flujos nuevos de la Entrega 4
./20-flujo-necesidad-y-stock.sh
./21-flujo-parcialidad-por-tipo.sh
./22-contratos-del-bot.sh
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
| Procesar donador, misiones e insignias | `12` | cubierto |
| Estadísticas cruzando Donadores e Incentivos | `13` | cubierto |
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
- **Más de un Worker en paralelo.** El enunciado pide soportarlo. Verificarlo requiere levantar
  dos y observar cómo se reparten los mensajes.
- **Las métricas y el dashboard.** Los scripts leen algunos contadores para diagnosticar, pero
  no validan que el dashboard esté completo.
