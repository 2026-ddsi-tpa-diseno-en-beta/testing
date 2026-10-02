# Preparación de entrega 5

Los cuatro servicios se compilan con Java 21 y `mvn package`. Las pruebas nuevas cubren reservas, períodos de necesidades, entregas en lote, revocación de misiones y contratos de MCP/Telegram.

## Prueba integrada aislada

Desde la carpeta TPA: `python testing/local/probar_integracion.py`.
Levanta los cuatro JAR con bases H2 nuevas, rechaza puertos ocupados y cierra únicamente sus propios procesos. Las configuraciones locales reemplazan las de producción. No utiliza las bases ni credenciales de Render.

Verifica los seis flujos, categorías e insignias, revocación por quejas, reservas desde stock, entrega recurrente con varios paquetes, OpenAPI y Prometheus. RabbitMQ se sustituye por el callback HTTP del worker: esta prueba no demuestra distribución de mensajes entre workers reales.

## Logs, métricas y alertas

Cada servicio devuelve y propaga `X-Trace-Id`. Los logs incluyen componente, instancia y request. Para centralizarlos configurar `BETTERSTACK_SOURCE_TOKEN` y `BETTERSTACK_INGEST_URL` en cada API y worker. El envío a BetterStack requiere comprobar la recepción en la cuenta del equipo.

En `observabilidad`: `docker compose up -d`. Prometheus queda en localhost:9090, Grafana en localhost:3000 y Alertmanager en localhost:9093. Las APIs se esperan en los puertos 8081–8084. Para Render cambiar los targets de prometheus.yml por los hosts reales y configurar HTTPS.

Se alertan caídas, errores HTTP, rechazos, falta de progreso del matchmaking, ocupación, revocación y errores del cron. Las siete reglas pasaron `promtool check rules`; cuatro escenarios pasaron `promtool test rules observabilidad/alertas.test.yml`: caída, falta de callbacks, primeras donaciones rechazadas y flujo normal sin falsas alarmas. El CI valida las reglas y la configuración. Alertmanager muestra alertas; su receptor debe configurarse para notificar por un canal real. Los contenedores del stack completo no se ejecutaron localmente en esta revisión.

## MCP

La implementación está en el repositorio independiente `mcp-server`, ubicado junto a `testing` dentro de TPA. Contiene el servidor MCP, gateway HTTP, catálogo y pruebas unitarias. Las APIs conservan las reglas de negocio; `testing` contiene los escenarios de integración y una copia del contrato en `contratos/tools.json`. `python mcp-server/scripts/generar_catalogo.py` regenera el catálogo y sus copias desde TPA. Para probar los seis flujos por MCP, compilar el nuevo repo y ejecutar `python testing/local/probar_integracion_mcp.py`.

## Telegram

Configurar `TELEGRAM_BOT_USERNAME`, `TELEGRAM_BOT_TOKEN` y las cuatro variables `DONACIONES_API_URL`, `DONADORES_API_URL`, `LOGISTICA_API_URL`, `INCENTIVOS_API_URL`. Usar `/admin` y `/ayuda logistica` (o el componente deseado). Cada herramienta del catálogo tiene un comando con igual nombre. Ejemplo: `/realizar_donacion {"donadorID":"1","depositoID":"1","productoID":"1","descripcion":"Alimentos","cantidad":10}`. Los comandos existentes con separadores `|` siguen disponibles.

La selección `/admin` es un rol para la demo, no autenticación. La verificación local del bot usa servidores HTTP de prueba; falta probar mensajes con el token real.

## Para cerrar la entrega

Revisar los diagramas y el informe en Modelo_Arquitectura/entrega5; desplegar las versiones nuevas coordinadamente; verificar migraciones de la base existente, dos workers con RabbitMQ, logs recibidos y una alerta real; conectar Claude Desktop y Telegram. El procesamiento usa llamadas HTTP entre servicios, sin transacción distribuida: una caída a mitad de una entrega puede requerir conciliación. No afirmar validación en producción a partir de las pruebas H2.
