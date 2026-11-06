# Entorno integrado

Requiere Docker Compose, Java 21 y Python 3. Los repositorios de los servicios deben ser carpetas hermanas de `testing`.

Compilar MCP con `mvn package` en `mcp-server`. Desde esta carpeta:

```sh
docker compose up -d --build
python probar_demo.py
python probar_demo.py --mcp
```

El entorno incluye cuatro bases PostgreSQL, MongoDB, RabbitMQ, dos workers, las cuatro APIs, Consultas y Gateway. El ensayo crea datos propios y verifica los seis flujos y los cuatro reportes por el gateway local. No simula callbacks. Guarda los resultados en `evidencia.local/`. Los puertos publicados se limitan a loopback; las credenciales del Compose son solo para este entorno.

`docker compose down` detiene los servicios y conserva los volúmenes.

Para probar reintentos con fallos HTTP controlados y bases H2, desde la carpeta que contiene los repositorios:

```sh
python testing/entrega6/probar_regresiones.py --build-root RUTA_A_TPA_COMPILADO --output RUTA_DE_RESULTADOS
```

Esta segunda suite simula los callbacks de workers; no conecta RabbitMQ ni MongoDB. `JAVA_EXE` permite indicar el ejecutable de Java 21.

## Consultas

Importar `DonaTrack_Entrega6.postman_collection.json` y usar la URL del gateway. Las cuatro consultas se exponen bajo `/api/consultas`: `/donadores/{id}/ficha`, `/necesidades/urgentes`, `/depositos/reporte` y `/calidad`. Esperar la propagación de eventos después de una escritura.

Cada módulo publica con `READ_MODEL_PUBLISHER_ENABLED=true`; Consultas consume con `READ_MODEL_MESSAGING_ENABLED=true`. Deben compartir el broker y usar la cola de lectura `donatrack.readmodel.v1.events`. La configuración de matchmaking es independiente del publisher de lectura.

## Alarmas por email

Confirmar qué Grafana usa el grupo. Grafana Cloud no necesita SMTP propio; una instalación propia requiere configurar un proveedor SMTP. No hace falta levantar un servidor SMTP nuevo si ya existe un proveedor disponible.

Verificar el contacto Email, los destinatarios de todos los integrantes y la política asociada a la regla de negocio. La validación requiere provocar la condición de la regla y recibir el correo; el botón de prueba del contacto por sí solo no verifica el recorrido completo. El Compose anterior no envía emails.

[Configuración de email en Grafana](https://grafana.com/docs/grafana-cloud/alerting-and-irm/alerting/configure-notifications/manage-contact-points/integrations/configure-email/).
