# Revisión final de entrega 5 — 2 de octubre de 2026

## Conclusión

La implementación Java cubre los seis flujos y separa correctamente servidor MCP, APIs, bot y pruebas. El ensayo automatizado usa APIs reales con persistencia H2 aislada; no acredita las cuentas externas ni la migración de PostgreSQL existente. Para cerrar la entrega hay que completar el ensayo de infraestructura indicado en [SETUP_PRESENTACION.md](SETUP_PRESENTACION.md).

## Consigna y evidencia

| Requisito | Estado del código / verificación | Pendiente externo |
|---|---|---|
| Implementación Java | Cuatro APIs, workers, bot y MCP en Java; scripts Python auxiliares | Java 21 en la máquina de demo |
| MCP local conectado con Claude | Repo independiente, SDK Java, stdio, 74 tools; cinco pruebas de gateway y prueba de protocolo | Claude Desktop debe mostrar y ejecutar herramientas reales |
| Reglas de negocio en los componentes | MCP valida contrato y llama por HTTP; no decide stock, categorías ni entregas | URLs reales y servicios accesibles |
| Seis flujos integrados | Seis flujos por MCP, 25 tools contra cuatro APIs reales; reservas, entrega recurrente en lote y revocación comprobadas | Repetir con PostgreSQL y RabbitMQ reales |
| ABM y consultas por Telegram | Catálogo compartido de comandos y compatibilidad con comandos anteriores; siete pruebas | Token real y una instancia de long polling |
| Logging centralizado | Appender Logtail y MDC en APIs/workers, propagación HTTP/RabbitMQ, eventos del dominio | Ver logs en Better Stack y correlacionarlos durante demo |
| Métricas del negocio | Donaciones, quejas, donadores, necesidades, entregas, stock, incentivos y workers; dashboard de 16 paneles | Scrape o exporter y dashboard con datos reales |
| Alarmas | Ocho reglas y cinco escenarios con promtool; identifica worker que falla | Receiver real y prueba de firing/resolved |
| Documentación completa | Guías, OpenAPI, modelos y seis secuencias por componentes en los repos | Revisar y entregar informe integrado PDF en el aula |

## Cambios de esta revisión

- Logística API y worker exportan Prometheus por defecto. Se agregó una prueba usando la configuración de producción, para que un override H2 no esconda otra desactivación accidental.
- Datadog y OTLP se habilitan explícitamente por entorno. Sin credenciales el servicio puede funcionar y exportar Prometheus.
- Donadores ya no fija credenciales PostgreSQL/Datadog en el archivo de configuración; Donaciones tampoco usa un fallback de contraseña PostgreSQL. Es necesario cargarlas en el despliegue y rotar las anteriores, que permanecen en el historial.
- Métricas nuevas de necesidades creadas y unidades entregadas: la reserva de stock no cuenta como entrega. La prueba integrada exige dos necesidades y 40 unidades recibidas en su escenario.
- El worker valida el formato de traceId y restaura el MDC anterior incluso si falla. Los errores se propagan para que RabbitMQ aplique reintentos y DLQ.
- Dashboard ampliado y alarma por worker con errores. La ocupación se describe explícitamente como total, porque las métricas actuales agregan todos los depósitos.
- Configuración ejemplo de Prometheus remoto con las cuatro APIs y ambos workers. Comprobador externo de sólo lectura para salud, OpenAPI y métricas.
- Guías de los cuatro módulos actualizadas para apuntar al repo MCP independiente.

## Evidencia local

Las pruebas de las cuatro APIs pasaron; Logística pasó `verify` y cobertura de instrucciones 81,37 % (mínimo 80 %). Los reportes registran 145 tests activos contando bot y MCP: Logística 30, Donaciones 83, Donadores 10, Incentivos 10, Telegram 7 y MCP 5. Hay tests de plantilla omitidos (42 Logística, 42 Donaciones y 30 Donadores): no se cuentan como aprobados. No se modificaron archivos de cátedra ni el workflow Classroom existente.

Los seis flujos volvieron a pasar por MCP después de estos cambios, incluyendo validación de métricas y los endpoints del nuevo comprobador externo. Las ocho reglas de alertas tienen cinco escenarios de promtool aprobados. Los resultados H2 y logs están en `TPA/tmp/revision-entrega5/integracion-mcp`; no contienen evidencia de recepción en Better Stack o entrega de mensajes en Telegram/Claude.

## Evaluación y mejoras priorizadas

1. **Primero el ensayo externo completo.** Falta acreditar broker con dos consumidores, persistencia PostgreSQL, recepción de logs, notificación de una alerta, Claude y bot reales. La lista completa de variables y pasos está en la guía de setup.
2. **Consistencia entre componentes.** La transacción JPA local no abarca llamadas HTTP ni publicaciones a otro servicio. Un fallo después de un efecto remoto puede dejar una operación parcial. Para un siguiente incremento: outbox, claves de idempotencia de negocio y compensaciones/conciliación. Los callbacks repetidos ya tienen protección, pero eso no resuelve todos los fallos distribuidos.
3. **Métricas por depósito y de broker.** La ocupación global puede esconder un depósito lleno; agregar gauges con ID del depósito y alertar por instancia. Para RabbitMQ mostrar queue depth, ready/unacked y DLQ con su exporter o integración del proveedor. Actualmente se mide el resultado de matchmaking, no toda la salud del broker.
4. **Tiempos y SLO.** Hay duración media HTTP y contadores. Para diagnóstico más fino agregar histogramas/p95 de HTTP, tiempo en cola y duración de flujos completos; acotar etiquetas a valores controlados, sin IDs de donación o traceId en métricas.
5. **Claridad de respuesta al usuario.** Telegram y MCP exponen bastante JSON técnico. Los IDs y enums permiten operar, pero conviene mejorar resúmenes, instrucciones de seguimiento y mensajes de errores de integración. `/admin` es un rol de demo, no autorización para un despliegue público con usuarios externos.
6. **Mantenibilidad.** Algunas fachadas concentran negocio, coordinación HTTP y persistencia. Separar casos de uso y repositorios facilitaría pruebas y manejo de fallos. Conviven naming/etiquetas de métricas históricos; el scrape asigna el componente y el dashboard mantiene esos nombres para no romper compatibilidad.
7. **Migraciones y evidencia documental.** Hibernate `update` no garantiza reparar datos viejos ni mantener correctamente períodos/categorías. Revisar datos existentes y adoptar migraciones versionadas. Confirmar informe PDF integrado: la consigna fija el 03/10/2026 a las 08:20.

## Formato de logs

Consola: texto legible con hora (`HH:mm:ss.SSS`), nivel, logger y pares clave/valor; operaciones con `traceId`, requestId, componente e instancia en MDC. Better Stack: eventos enviados por el appender Logtail con campos MDC estructurados. No se aplica color ANSI al canal MCP: stdout es JSON-RPC y stderr contiene diagnósticos. Los mensajes no llevan el cuerpo completo de la solicitud.

Mejora de formato pendiente: agregar fecha completa y zona horaria ISO 8601 al patrón de consola para evitar ambigüedad entre días y entre las máquinas del grupo y Render. Los colores no deben formar parte de los datos enviados a la plataforma centralizada.

Los logs de arranque no siempre tienen contexto de petición; se distinguen por APP_NAME. Correlación con traceId no equivale a Datadog APM distribuido. Una demostración debe mostrar la misma operación en varios servicios, incluyendo el worker, y no sólo logs genéricos de arranque.
