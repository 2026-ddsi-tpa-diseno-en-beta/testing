# Configuración externa y ensayo de entrega 5

El código Java y el CI no sustituyen la demostración con las cuentas reales. Este documento reúne la configuración para ese ensayo. No copiar las configuraciones H2 de `local` al despliegue.

## 1. Repositorios, herramientas y despliegue

Clonar los nueve repos como carpetas hermanas en TPA. El servidor real está en `mcp-server`; `testing` contiene pruebas y contratos. Usar Java 21, Maven, Claude Desktop, Telegram y una herramienta HTTP (Postman o Swagger). Python sólo ejecuta los scripts auxiliares. Docker es necesario si se usa el stack local de observabilidad.

En Render desplegar el último `main` de las cuatro APIs usando sus Dockerfiles, y dos instancias de worker desde Logística. Un push no garantiza que Render haya desplegado ese commit: revisar el SHA del deploy y sus logs. Las APIs ejecutan `java -jar app.jar`; cada worker ejecuta `java -jar worker.jar` en el Docker Command del mismo Dockerfile de Logística.

Para poder mostrar salud y métricas de los workers por HTTP, desplegarlos como Web Services o servicios con URL HTTP accesible desde Prometheus. Un Background Worker sin URL pública necesita métricas por push (OTLP) o un Prometheus dentro de su red. Cada worker activa su perfil automáticamente y no necesita PostgreSQL.

## 2. PostgreSQL e integraciones REST

Cada API necesita una base PostgreSQL independiente y estas variables:

```text
SPRING_DATASOURCE_URL=jdbc:postgresql://HOST:5432/BASE?sslmode=require
SPRING_DATASOURCE_USERNAME=USUARIO
SPRING_DATASOURCE_PASSWORD=CONTRASEÑA
```

Usar las credenciales del proveedor y una URL JDBC; una URL `postgres://` no es equivalente. Mantener el `PORT` que asigna Render. Para un ensayo con datos nuevos, usar bases de demo; no borrar las bases del equipo. El esquema se actualiza con Hibernate `update`, que no reemplaza una migración revisada de datos existentes (en particular períodos recurrentes y relaciones de misiones).

Las URLs deben apuntar al entorno que se presenta. Cargar nombres exactos:

| Proceso | Variables y destino |
|---|---|
| Donaciones | `DONADORES_Y_ENTIDADES_URL` → Donadores; `LOGISTICA_URL` → Logística |
| Donadores y Entidades | `URL_DONACIONES`, `URL_LOGISTICA`, `URL_INCENTIVOS` |
| Logística API | `DONADORES_URL`, `DONACIONES_URL`, `RABBITMQ_URL` |
| Worker 1 y 2 | `DONADORES_URL`, `LOGISTICA_API_URL`, `RABBITMQ_URL`, `WORKER_ID` diferente |
| Incentivos | `SPRING_APPLICATION_JSON` con las dos propiedades exactas del ejemplo siguiente |
| MCP y bot | `DONACIONES_API_URL`, `DONADORES_API_URL`, `LOGISTICA_API_URL`, `INCENTIVOS_API_URL` |

En Incentivos:

```json
{"donatrack.donaciones.url":"https://TU-DONACIONES","donatrack.donadores-y-entidades.url":"https://TU-DONADORES"}
```

Para identificar instancias en logs usar `INSTANCE_ID` en Donaciones, Donadores e Incentivos. En Logística usar `INSTANCE_NAME`; en los workers `WORKER_ID=worker-1` y `WORKER_ID=worker-2`. `APP_NAME` identifica cada aplicación en Better Stack.

Comprobar en cada API `/actuator/health` (`UP`), `/v3/api-docs` (JSON), `/swagger-ui/index.html` y `/actuator/prometheus` (texto). En los workers comprobar salud y métricas. Una salud correcta no prueba todas las llamadas entre APIs: ejecutar los flujos al terminar la configuración.

Comprobación automática de lectura desde TPA:

```sh
python testing/local/verificar_externos.py --donaciones "URL_DONACIONES" --donadores "URL_DONADORES" --logistica "URL_LOGISTICA" --incentivos "URL_INCENTIVOS" --worker "URL_WORKER_1" --worker "URL_WORKER_2"
```

El script no crea, modifica ni borra datos. Comprueba salud, OpenAPI y métricas de negocio; no sustituye la inspección de logs, broker y clientes reales.

## 3. RabbitMQ

Crear o usar el broker del equipo, usuario y virtual host. Cargar su URL AMQP/AMQPS completa en `RABBITMQ_URL`, idéntica en API y ambos workers. Usar el puerto y TLS indicados por el proveedor; no confundir la URL del panel web con la conexión AMQP. Si el nombre del virtual host o contraseña tiene caracteres reservados, usar la URL codificada que provee el broker.

La aplicación declara `logistica.exchange`, cola durable `logistica.matchmaking`, routing key `logistica.donacion.pendiente`, dead-letter exchange `logistica.dlx` y cola `logistica.matchmaking.dlq`. No recrear ni purgar colas del equipo para solucionar un error de declaración sin revisar primero sus argumentos.

Demostración: verificar dos consumidores en la cola, configurar el algoritmo de un depósito, registrar varias donaciones y comprobar que ambos workers participan, realizan callbacks y se guardan asignaciones. Inspeccionar mensajes ready/unacked, reintentos y DLQ. Los workers compiten por los mensajes; una sola donación no demuestra reparto entre ambos. Detener uno debe permitir que el otro continúe. La prueba automatizada H2 simula callbacks y no valida este broker.

## 4. Better Stack y formato de logs

Crear la fuente del grupo y obtener su Source token y su Ingesting host. En cada API y worker:

```text
BETTERSTACK_SOURCE_TOKEN=TOKEN
BETTERSTACK_INGEST_URL=https://HOST_DE_INGESTA
APP_NAME=donatrack-NOMBRE_DEL_COMPONENTE
```

Aplicar los cambios mediante despliegue. No usar por costumbre el host genérico si la fuente ofrece otro endpoint. La consola muestra hora, nivel, logger, evento y contexto `trace`, `instance`, `component`, `req`. Better Stack recibe eventos mediante Logtail, incluyendo los campos MDC `traceId`, `requestId`, `instanceId`, `component`, `workerId`. Los IDs de dominio están en los mensajes; no se registra el cuerpo completo de las peticiones.

Generar una donación con `X-Trace-Id: ensayo-entrega5-001`, buscar ese ID en Live tail y seguirla entre API, RabbitMQ, worker y callback. Verificar que `component` y la instancia identifican al emisor. Los logs de arranque pueden no tener MDC porque aún no hay petición; usar también `APP_NAME`. El UUID `traceId` es correlación propia, no una implementación de Datadog APM/OpenTelemetry tracing.

El MCP reserva stdout para JSON-RPC y envía diagnósticos a stderr; no se deben agregar logs de consola a su stdout. Bot y MCP tienen diagnósticos locales: sus logs no están integrados automáticamente al appender Spring de las APIs.

Se retiraron del archivo de Donadores credenciales de PostgreSQL y Datadog que estaban fijadas en el código. Cargarlas en el despliegue y rotarlas: quitar un valor del último commit no lo borra del historial Git.

## 5. Métricas: Prometheus/Grafana y Datadog

El stack versionado contiene dashboard y reglas Prometheus. Desde TPA:

```sh
docker compose -f testing/observabilidad/compose.yaml up -d
```

Antes de usar APIs remotas, copiar/adaptar `observabilidad/prometheus.render.example.yml` a `prometheus.yml`: reemplazar los seis hosts por los de las cuatro APIs y ambos workers. Los targets tienen formato `HOST:443`, `scheme: https` y ruta `/actuator/prometheus`. Si los servicios son locales, conservar la configuración con `host.docker.internal:8081–8084` y agregar los puertos reales de los workers.

Logística API y workers exportan Prometheus por defecto; se puede desactivar con `PROMETHEUS_ENABLED=false`. Revisar también que no exista un override antiguo `MANAGEMENT_PROMETHEUS_METRICS_EXPORT_ENABLED=false` en Render.

Prometheus: `http://localhost:9090/targets` debe mostrar todos los procesos configurados en UP. Grafana: `http://localhost:3000`; en un volumen nuevo sin overrides usa admin/admin y solicita cambiar la contraseña. El dashboard provisionado muestra negocio, entregas, quejas, necesidades, unidades, workers y duración media HTTP. Los contadores se reinician con el proceso: para comparar períodos usar `increase`/`rate`. La ocupación actual es agregada; no detecta un depósito individual lleno si otros están vacíos.

### Datadog

Datadog es una alternativa/complemento de métricas; la consigna no obliga a contratar ambos proveedores. Donaciones, Donadores e Incentivos tienen exportador Micrometer directo:

```text
DATADOG_ENABLED=true
DATADOG_API_KEY=API_KEY_DE_LA_ORGANIZACION
DATADOG_URI=https://API_HOST_DEL_SITE
DATADOG_STEP=30s
```

Elegir el API host del site de la cuenta (US/EU/etc.), no la URL de la pantalla del dashboard. No se necesita Application key para enviar esas métricas. Revisar Metrics Explorer tras varias ventanas y crear dashboard/monitores con los nombres Micrometer (`donadores.necesidades.registradas`, `logistica.entregas.reportadas`, etc.); los nombres Prometheus usan `_` y sufijos como `_total`.

Logística usa Prometheus y exportador OTLP para Grafana, no un registry Datadog directo. `DATADOG_ENABLED=true` por sí solo no agrega ese registry a Logística. Para centralizar también sus métricas en Datadog, configurar un Datadog Agent con integración OpenMetrics que scrapee sus endpoints y los de los workers, o hacer una integración OTLP admitida por el receptor elegido. No se configuró Datadog APM ni envío de logs a Datadog: los logs centralizados van a Better Stack.

### OTLP/Grafana Cloud

Opcional para Logística API y workers:

```text
GRAFANA_OTLP_METRICS_ENABLED=true
GRAFANA_OTLP_METRICS_URL=URL_COMPLETA_DEL_ENDPOINT_DE_METRICAS
GRAFANA_OTLP_HEADERS=Basic CREDENCIAL_CODIFICADA
```

Obtener endpoint y autenticación del panel de conexión de la cuenta. El endpoint debe corresponder a OTLP HTTP/protobuf para métricas (habitualmente termina en `/v1/metrics`), no a la UI de Grafana. Sin esta configuración, dejar la exportación desactivada y usar Prometheus. Si la demo usa Grafana Cloud, el dashboard local y las reglas de Alertmanager no aparecen allí automáticamente: importar/adaptar dashboard y crear reglas/contact points en ese entorno.

## 6. Alarmas y receptor de notificaciones

Prometheus envía las alertas a Alertmanager (`http://localhost:9093`). Hay reglas para caída, errores HTTP, rechazos, matchmaking detenido, ocupación global, revocaciones, cron y errores de worker. La regla del worker necesita scrape de sus métricas. El receiver `consola` permite verlas en UI pero no envía notificaciones a una persona.

Para notificar por Telegram, crear un bot de alertas en BotFather, iniciar conversación o agregarlo al grupo de destino, obtener su token y chat ID numérico (puede ser negativo en grupos), y configurar un receiver real. Ejemplo de estructura para adaptar en un archivo local:

```yaml
route:
  receiver: telegram
  group_by: [alertname, component]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 1h
receivers:
  - name: telegram
    telegram_configs:
      - bot_token_file: /run/secrets/telegram_bot_token
        chat_id: 123456789
        send_resolved: true
```

Montar el archivo del token dentro del contenedor en esa ruta y montar la configuración adaptada como `/etc/alertmanager/alertmanager.yml`. Validarla con `amtool check-config` antes de reiniciar. Alertmanager no reemplaza automáticamente `${VARIABLE}` en YAML. No versionar el token. También se puede configurar email o webhook según el canal del equipo.

Ensayo: detener una API del entorno de demo, esperar scrape y los dos minutos de la regla, comprobar alerta firing y recepción; volver a iniciarla y verificar resolución. Generar una revocación real para mostrar una alarma de negocio. No modificar permanentemente umbrales para simular que el sistema funciona.

## 7. Claude Desktop

Instalar Claude Desktop, iniciar sesión y tener acceso a una conversación. Compilar el MCP con Java 21 (`mvn package` dentro de `mcp-server`). Generar la configuración desde ese repo:

```sh
python scripts/crear_config_claude.py --java "RUTA_ABSOLUTA_JAVA_21" --donaciones "URL_DONACIONES" --donadores "URL_DONADORES" --logistica "URL_LOGISTICA" --incentivos "URL_INCENTIVOS"
```

Agregar la entrada donatrack de `target/claude-desktop.config.json` a `mcpServers` en `%APPDATA%/Claude/claude_desktop_config.json`, conservando otros servidores. Reiniciar Claude. El cliente inicia Java/JAR por stdio: no hay puerto HTTP MCP ni despliegue del MCP en cada API. Para ejecutar el servidor sólo hace falta Java; Python genera configuración auxiliar.

Verificar que Claude muestra las herramientas. Pedir primero salud y listado de productos; después ejecutar los seis flujos con los IDs reales de la demo. Claude debe usar tools y mostrar el resultado del sistema. Ante fallas revisar `%APPDATA%/Claude/logs`, rutas absolutas, Java y conectividad. Las URLs deben ser alcanzables desde la PC de presentación.

## 8. Bot Telegram

Configurar `TELEGRAM_BOT_USERNAME` (nombre del bot), `TELEGRAM_BOT_TOKEN` y las cuatro variables `*_API_URL` de la tabla. Compilar dentro de `telegramBot/untitled` y ejecutar `java -jar target/donatrack-telegram.jar`. Usa long polling; mantener una sola instancia usando ese token. Si el mismo bot tenía webhook, retirarlo antes de iniciar long polling. El bot de alertas puede ser otro para evitar confusión.

Usar `/admin` y `/ayuda COMPONENTE`. Cada herramienta tiene un comando del mismo nombre: altas/modificaciones reciben JSON, operaciones sobre un recurso reciben su ID. Los comandos antiguos con `|` siguen vigentes. Las respuestas son JSON técnico, útil para IDs pero mejorable para usuarios finales. `/admin` selecciona un rol de demo: no autentica administradores.

## 9. Datos, red y ensayo completo

Precargar donador verificado, entidad, depósito con capacidad y algoritmo, categorías/subcategorías/productos, necesidad extraordinaria y recurrente, insignias y misiones con categorías inicial/final coherentes. Registrar sus IDs en la colección Postman. Para demostrar la misión de 20 donaciones exitosas precargar su secuencia o prepararla antes; no gastar la presentación en altas repetitivas.

Ejecutar: donar → confirmar asignación real del worker → reportar entrega → registrar queja → procesar donador → consultar estadísticas; luego crear una necesidad que reserve stock y entregar su lote recurrente. Mostrar que reservar stock no cuenta como entrega. Revisar estados, cantidades y revocaciones desde otro canal (API/Telegram/Claude).

Preparar internet/hotspot, credenciales de acceso a los paneles, permisos del grupo y una sola máquina ejecutando el bot. Comprobar arranque y tiempos de respuesta antes de presentar; si el hosting suspende servicios, despertarlos previamente y mantenerlos activos durante el ensayo. La consigna recomienda UptimeRobot o similar; configurar los health checks y desactivarlos después si corresponde al plan utilizado.

La consigna también pide informe integrado PDF y seis secuencias por componentes, además de especificación de APIs y modelos. Los Markdown y el Swagger versionado no demuestran que ese PDF se haya entregado al aula virtual. Verificar ese entregable por separado.

## Fuentes de configuración

- [Consigna: logging de referencia](https://github.com/ezequieljsosa/logs-demo-service)
- [Better Stack Java](https://betterstack.com/docs/logs/java/)
- [Micrometer y Datadog](https://docs.micrometer.io/micrometer/reference/implementations/datadog.html)
- [Datadog y Micrometer/OpenMetrics](https://docs.datadoghq.com/metrics/guide/micrometer/)
- [Configuración de Alertmanager](https://prometheus.io/docs/alerting/latest/configuration/)
- [MCP local en Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers)
- [Docker y comandos de despliegue en Render](https://render.com/docs/docker)
