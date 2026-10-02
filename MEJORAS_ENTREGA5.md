# Mejoras de observabilidad y Telegram — entrega 5

## Relación con las consignas

Las mejoras preservan las responsabilidades de los cuatro componentes, los contratos de la cátedra y los seis flujos principales. No cambian algoritmos, umbrales de misiones, estados, reglas de productos, cantidades de entrega ni el orden de las llamadas del negocio.

| Entrega | Restricción conservada | Validación |
|---|---|---|
| 1 | Modelo y reglas de donaciones, donadores, necesidades, logística e incentivos | Pruebas existentes del dominio; instrumentación fuera de las decisiones |
| 2 | API existente; recurrentes sin entregas parciales ni varias entregas por período | Contratos sin cambios; pruebas de lote recurrente y períodos |
| 3 | Persistencia y responsabilidades separadas; métricas en los cuatro componentes | Gauges consultan datos persistidos; tablero identifica componentes |
| 4 | Workers stateless con callback a Logística; satisfacción al entregar, no al reservar | Pruebas de worker y seis flujos integrados |
| 4 | Bot simple: selección inicial donador/admin, comandos y respuesta | Comandos originales y formatos con `|` siguen disponibles |
| 5 | MCP local Java con Claude, sin duplicar negocio; consultas y ABM del bot en todos los componentes | Catálogo de 74 operaciones conservado y prueba por MCP |
| 5 | Logs centralizados, métricas del dominio y alarmas | Appender Better Stack, tablero y escenarios promtool; recepción real requiere ensayo externo |

La entrega 4 indica: «En principio debe ser simple, con que reciba un comando y retorne una respuesta es suficiente». Por eso se descartaron los asistentes de varios pasos del plan preliminar. La navegación `/pagina N` sólo presenta una respuesta ya obtenida; no cambia operaciones ni repite llamadas HTTP.

## Telegram

- `/start`, `/donador`, `/admin` y `/menu` conservan la selección y opciones de la entrega 4.
- Registro de donadores, estadísticas, búsquedas; entidades y necesidades mantienen sus comandos.
- Se conservan las consultas y ABM de los cuatro componentes y los alias del grupo.
- Las respuestas JSON se presentan como campos legibles, conservando referencias completas, estados exactos y todos los datos, incluidos campos nuevos del backend.
- Respuestas largas se consultan con `/pagina N`; vencen a los diez minutos, se separan por chat y no ejecutan nuevamente escrituras.
- Los errores explican la acción posible y muestran una referencia de soporte, sin copiar el cuerpo interno de error.
- `TELEGRAM_ADMIN_CHAT_IDS` es opcional y contiene chat IDs separados por comas. Sin configurar, se mantiene la elección de rol prevista por la consigna. Si se configura, limita qué chats pueden elegir admin. Para restringir personas, usar chats privados; un chat ID de grupo autoriza al grupo y no identifica a cada miembro. Esto no sustituye autenticación en las APIs.

## Métricas y significado

- Intentos, mensajes terminados y errores de worker se separan. «Procesados» cuenta intentos finalizados correctamente, incluidos resultados válidos sin asignación; no promete unicidad ante redelivery.
- Resultados: asignado, sin necesidades o sin elegibles. Un resultado sin asignación no es un error técnico.
- Ocupación por depósito detecta casos ocultos por la ocupación global. Las etiquetas de depósito pertenecen al conjunto administrado; no se etiquetan donaciones, paquetes ni usuarios individuales.
- Necesidades: objetivos, cobertura física y faltantes por tipo, en el período vigente. Cobertura usa el valor persistido del dominio, limitado por su objetivo; no representa el total bruto recibido.
- Logística muestra unidades reservadas por asignaciones pendientes. No se suman a cobertura física.
- Antigüedad de asignación pendiente: desde su fecha de asignación. Antigüedad de donación INGRESADA: desde ingreso, pudiendo estar en stock o asignada; no es edad de la cola RabbitMQ.
- Duración de entrega: asignación hasta reporte, por paquete. Duración ingreso/aceptación: primera aceptación de la donación, que puede tener varios paquetes. Ninguna equivale automáticamente a entrega completa de todos los sobrantes.
- HTTP e integraciones exponen histogramas para p95. Las llamadas se agrupan por host de destino, método y status, sin URLs completas ni IDs.
- Incentivos: duración del cron, timestamp del último ciclo exitoso y pendientes/fallidos del último ciclo. Cero como timestamp significa que aún no hubo éxito desde el arranque.
- Los gauges de estado usan snapshots de hasta diez segundos. Los contadores y timers se reinician con el proceso; usar `increase`/`rate` para períodos observados, sin tratarlos como balance contable.

## Alarmas

Se conserva detección de caída, falta de progreso y errores, y se mejora:

- Proporción de HTTP 5xx mayor al 5%, con al menos cinco solicitudes en cinco minutos.
- Rechazos mayores al 30%, con al menos cinco intentos en cinco minutos.
- Depósito individual al 90% de ocupación.
- Tres revocaciones en diez minutos, en lugar de alarmar por una revocación aislada esperable.
- Asignaciones sin entrega durante más de 24 horas.
- Cron sin un ciclo exitoso durante cinco minutos, tolerando arranque; pensado para intervalo de 60 segundos.
- DLQ con mensajes, si se conectó el exporter del broker.

Son umbrales operativos iniciales, no nuevas reglas de negocio. Revisarlos con el volumen real; adaptar el umbral del cron si se cambia su intervalo. La ausencia de una serie de Rabbit no debe interpretarse como una cola vacía.

## Acciones externas del equipo

1. Render: desplegar los nuevos commits de las cuatro APIs y dos workers. Comandos y URLs existentes no cambian. No desactivar Prometheus; comprobar salud y scrape en todos los procesos.
2. Better Stack: configurar Source token, ingest URL y APP_NAME también en la PC/proceso del bot y MCP si se quieren centralizar sus eventos. El MCP mantiene todos sus logs en stderr; stdout continúa reservado para JSON-RPC. No versionar credenciales.
3. Prometheus/Grafana: montar el dashboard y reglas actualizados. Los nuevos histogramas aumentan series; vigilar el límite del proveedor. Grafana Cloud necesita importar el dashboard y adaptar las alertas; no recibe la configuración local automáticamente.
4. Alertmanager: copiar `observabilidad/alertmanager.telegram.example.yml` a `alertmanager.telegram.local.yml`, poner el chat ID real y crear `telegram-bot-token.local`. Usar el overlay `compose.telegram.example.yaml`; validar con amtool. Los archivos `.local` se ignoran en Git. Las variables `${...}` no se sustituyen automáticamente dentro del YAML.
5. RabbitMQ: consultar si el proveedor permite el plugin Prometheus/endpoint por cola. Si está disponible, agregar el job de `prometheus.rabbitmq.example.yml` con host, TLS y autenticación reales. El ejemplo usa el puerto por defecto 15692 y `/metrics/per-object`; no confundirlo con AMQP ni con el panel Management. Si no está disponible, mostrar Management y dejar constancia de que no hay alarmas automáticas de DLQ.
6. Bot: opcionalmente configurar `TELEGRAM_ADMIN_CHAT_IDS`. Mantener una sola instancia por token, selección inicial y todos los comandos de la entrega. No se requiere webhook ni un servicio adicional.
7. Claude: recompilar/usar el JAR MCP actualizado y reiniciar Claude. Conservar la configuración local de Java, rutas y URLs de las APIs. No se despliega MCP dentro de cada módulo.

Las variables exactas de PostgreSQL, conexiones entre APIs, Datadog y OTLP siguen documentadas en [SETUP_PRESENTACION.md](SETUP_PRESENTACION.md). Logística continúa sin registry Datadog directo: necesita OpenMetrics/OTLP compatible si se quiere centralizar allí. Ninguna cuenta externa fue reconfigurada automáticamente.

## Ensayo de aceptación

Ejecutar los seis flujos por MCP y comprobar que las reglas del dominio y sus estados coinciden con las APIs. Por Telegram probar ambos roles, los comandos originales, ABM de cada componente, un error de estado y una respuesta con varias páginas. Revisar que navegar páginas no crea recursos adicionales.

En observabilidad: buscar una donación por traceId y donacionId; distinguir reserva y entrega; mostrar un depósito lleno aunque la ocupación global sea baja; revisar resultados de ambos workers y un cron fallido que continúa con el siguiente donador. Para alertas probar disparo y resolución en un entorno de demo, sin purgar colas ni alterar datos del equipo.

La cobertura histórica por períodos cerrados y causas de rechazo detalladas requiere datos históricos específicos; estas métricas no inventan información que el modelo no persiste. Para decisiones auditables, consultar el dominio y su historial, además de la telemetría.
