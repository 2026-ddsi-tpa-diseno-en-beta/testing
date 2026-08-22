# DonaTrack — scripts de prueba

Scripts de terminal para cargar datos en las bases y verificar los flujos del sistema
integrado. Cada uno corre solo, imprime todo lo que hace, y compara lo esperado contra lo
obtenido.

Sirven para dos cosas: dejar el sistema listo antes de una demo, y darse cuenta de qué se
rompió cuando algo no funciona.

## Requisitos

Solo `bash` y `curl`, que ya vienen en macOS y Linux. Si tenés `jq` lo usa; si no, cae a
`python3`. No hay nada que instalar.

## Arranque rápido

```bash
git clone <este-repo> && cd testing
cp config.sh.example config.sh    # ajustar las URLs si cambiaron los deploys

./00-salud.sh                     # despierta los servicios (la primera vez tarda)
./01-seed.sh                      # carga las precondiciones
./10-flujo-registrar-donacion.sh  # y de acá en adelante, los flujos
```

O todo de una:

```bash
./correr-todo.sh 2>&1 | tee corrida.log
```

Para mostrar un cambio puntual sin imprimir todo el sistema:

```bash
./ver-estado.sh donacion --esperado ACEPTADA
./ver-estado.sh donador ok --esperado VERIFICADO
./ver-estado.sh asignacion --esperado COMPLETADA
./ver-estado.sh stock "$PRODUCTO" --esperado 1
```

Si no pasas un ID, usa los IDs que quedaron guardados en `.estado`.

## Los scripts

Ver también la [guía rápida](GUIA.md) con las recetas para casos concretos.

| Script | Qué hace |
|---|---|
| `ver-donador.sh` | Explica un donador: estado, puede-donar, quejas, estadisticas y donaciones por estado. |
| `ver-logistica.sh` | Explica Logistica: deposito, stock, paquete, asignacion y cola de matchmaking. |
| `ver-estado.sh` | Muestra un objeto puntual: donacion, donador, asignacion, necesidad, stock, paquete o deposito. Sirve para mostrar cambios de estado durante la demo. |
| `estado.sh` | Muestra el estado actual de los 4 módulos. Solo lecturas, no modifica nada. |
| `keepalive.sh` | Le pega a los 4 servicios cada 3 min para que Render no los duerma. **Dejarlo corriendo durante la presentación.** |
| `00-salud.sh` | Chequea que los 4 servicios respondan y los deja despiertos. **Correr siempre primero.** |
| `01-seed.sh` | Carga todas las precondiciones y guarda los IDs en `.estado`. |
| **Los 5 flujos de la demo** | |
| `10-flujo-registrar-donacion.sh` | Flujo 1: la cadena completa hasta que se crea la asignación. |
| `11-flujo-reportar-entrega.sh` | Flujo 2: el transportista reporta y verifica los 3 efectos. |
| `12-flujo-procesar-donador.sh` | Flujo 3: misiones, insignias y el cron de Incentivos. |
| `13-flujo-estadisticas.sh` | Flujo 4: compara lo que dice Incentivos contra lo que reporta Donadores. |
| `14-flujo-queja-baneo.sh` | Flujo 5: la queja end-to-end y los umbrales de estado del donador. |
| **Incentivos y misiones** | |
| `23-flujo-cumplir-mision-insignia.sh` | Crea una mision COMPLETITUD, la cumple con 3 categorias y verifica que se otorgue la insignia. |
| **Los flujos nuevos de la Entrega 4** | |
| `20-flujo-necesidad-y-stock.sh` | Validación del producto, consulta de stock y asignación inmediata (el caso N-1). |
| `21-flujo-parcialidad-por-tipo.sh` | Con stock insuficiente: EXTRAORDINARIA acepta parcial, RECURRENTE no. |
| `22-contratos-del-bot.sh` | Los endpoints que consume el bot, con los mismos bodies que él manda. |
| **Crear cosas de a una** (por argumento o preguntando) | |
| `cargar-quejas.sh` | Agrega quejas a un donador y muestra como cambian quejas, estado y puede-donar. |
| `modificar-necesidad.sh` | Cambia descripcion, cantidad, urgencia, tipo, producto o entidad de una necesidad existente. |
| `modificar-deposito.sh` | Cambia el algoritmo de matchmaking de un deposito y valida el antes/despues. |
| `crear-donador.sh` | Un donador, opcionalmente con N quejas para dejarlo en un estado concreto. |
| `crear-categoria.sh` | Una categoría, o una subcategoría si le pasás el padre. |
| `crear-producto.sh` | Un producto. Te avisa si va a fallar la validación del identificador. |
| `crear-entidad.sh` | Una entidad benéfica. |
| `crear-necesidad.sh` | Una necesidad, midiendo el stock antes y después. |
| `crear-deposito.sh` | Un depósito con su algoritmo de matchmaking. |
| `crear-mision.sh` | Una insignia y una misión, con la transición de categoría que le corresponde. |
| `donar.sh` | Donaciones con los parámetros que quieras: cuántas, de cuánto, de quién. |
| | |
| `correr-todo.sh` | Ejecuta todo en orden y deja un resumen por flujo. |
| `99-limpiar.sh` | Vacía las bases de los 4 módulos. Pide confirmación. |

Los `crear-*.sh` imprimen el ID por stdout y lo guardan en `.estado`, así que se pueden
encadenar:

```bash
CAT=$(./crear-categoria.sh --nombre Mobiliario)
PROD=$(./crear-producto.sh --nombre Mesa --descripcion "una mesa" --categoria "$CAT" --sin-identificador)
./donar.sh --producto "$PROD" --veces 5 --cantidad 10 --incremental
```

### Por qué correr `00-salud.sh` primero

Render en free tier duerme los servicios. El primer request de cada uno puede tardar **más de
90 segundos** y hacer fallar todo lo que venga después por timeout. En la última corrida
Incentivos tardó 146 segundos en despertar.

El día de una demo: correlo un rato antes, y dejá un uptimerobot apuntando a los 4.

## Cómo se leen las salidas

```
--> 1. Donaciones verifica el donador y registra la donacion
    GET donadores/xxx/puede-donar -> HTTP 200
    [OK] el donador puede donar
    [OK] la donacion nace en INGRESADA  (= INGRESADA)
```

- `[OK]` — se verificó y dio lo esperado
- `[FALLA]` — no dio lo esperado; imprime **esperado vs obtenido**
- `[AVISO]` — algo raro pero no concluyente
- Cada script termina con un resumen y sale con código `0` si no hubo fallas

Los logs van a **stderr** y los valores a **stdout**, así que si querés guardar la corrida
completa necesitás `2>&1`:

```bash
./correr-todo.sh 2>&1 | tee corrida.log
```

## Cuando algo falla

Los scripts no se limitan a decir que falló: diagnostican. El del flujo 1 lee las métricas de
RabbitMQ y distingue los casos:

- **`published=0`** → el mensaje no salió. Problema de conexión al broker.
- **`consumed=0`** → se publicó pero nadie lo consumió. No hay Worker escuchando.
- **`rejected>0`** → el Worker lo tomó y falló. Casi siempre `LOGISTICA_API_URL` mal seteada.

Y en cada caso imprime el comando concreto para arreglarlo o seguir investigando.

## Qué carga el seed

**Donaciones:** una categoría, una subcategoría, un identificador de código de barras y un
producto (con descripción de 4 palabras, para que pase la validación que pide 3 o más).

**Donadores y Entidades:** tres donadores —uno limpio, uno con 5 quejas (SOSPECHOSO) y uno con
9 quejas—, una entidad, y dos necesidades: una EXTRAORDINARIA de 100 unidades y una RECURRENTE
de 50.

**Logística:** un depósito de capacidad 1000 con el algoritmo `SUB_ATENDIDOS`. Verifica de paso
que el algoritmo arranque en `null`, como pide el enunciado.

**Incentivos:** una insignia y una misión `COMPLETITUD` (OCASIONAL → COLABORADOR).

> El donador con 9 quejas está a propósito: en la demo le sumás una y pasa a BANEADO.

Todo lleva el prefijo `TEST` para poder identificarlo. Los IDs quedan en `.estado`, que es un
archivo de `KEY=valor` que los demás scripts leen — por eso cada uno corre solo, sin depender
de haber ejecutado el anterior en la misma terminal.

## Datos que se escriben

**Estos scripts escriben en las bases de producción.** Es a propósito: la idea es poder dejar
el sistema cargado antes de una demo. Pero tenelo en cuenta antes de correrlos.

`99-limpiar.sh` vacía las bases usando los endpoints de admin. **Borra todo, no solo lo que
crearon los scripts**, así que si alguien cargó datos a mano para una demo, también se van.
Pide confirmación escribiendo `BORRAR`.

## Variables

Se pueden pisar por entorno sin tocar `config.sh`:

```bash
TIMEOUT=300 ./00-salud.sh                          # timeout por request
ESPERA=60 ./10-flujo-registrar-donacion.sh         # espera al worker
PREFIJO=DEMO ./01-seed.sh                          # prefijo de los datos
./10-flujo-registrar-donacion.sh 25                # cantidad a donar
./13-flujo-estadisticas.sh <donadorID>             # otro donador
./14-flujo-queja-baneo.sh umbrales                 # recorrer las 10 quejas
```

## Estado de los flujos

Última corrida: **18-08-2026**.

| Flujo | Estado | Detalle |
|---|---|---|
| 1 · Registrar donación | falla | La donación y el paquete se crean bien, pero **no hay Worker consumiendo la cola**. `published=2, consumed=0`. |
| 2 · Reportar entrega | bloqueado | Depende del flujo 1: sin asignación no hay nada que entregar. |
| 3 · Procesar donador | pasa | El progreso de misión es por donador y el cron está ejecutando. |
| 4 · Estadísticas | pasa | La integración Donadores → Incentivos trae las insignias correctamente. |
| 5 · Queja y baneo | pasa | Umbrales exactos: 1-4 VERIFICADO, 5-9 SOSPECHOSO con el aleatorio funcionando, 10 BANEADO. |

Para desbloquear el flujo 1 hay que levantar un Worker. El enunciado permite correrlo local
durante la entrega:

```bash
cd Componente_Logistica
SPRING_PROFILES_ACTIVE=worker \
RABBITMQ_URL=<la de CloudAMQP> \
DONADORES_URL=https://entrega-2-lolasimone.onrender.com \
LOGISTICA_API_URL=https://donatrack-api-logistica-diseno-en-beta.onrender.com \
java -jar target/*-worker.jar
```

## Agregar un script nuevo

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib/comun.sh"

exigir_estado DONADOR_OK          # corta si falta correr el seed

titulo "LO QUE ESTOY PROBANDO"
paso "1. Primer paso"
req GET "$URL_DONADORES/donadores/$DONADOR_OK"
verificar "el donador arranca verificado" "VERIFICADO" "$(campo '.estado')"

resumen                            # imprime el resumen y define el exit code
```

Funciones disponibles en `lib/comun.sh`: `titulo`, `paso`, `ok`, `falla`, `aviso`, `detalle`,
`verificar`, `req`, `campo`, `guardar`, `exigir_estado`, `resumen`.
