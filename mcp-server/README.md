# DonaTrack MCP

Módulo Java 21 independiente con SDK MCP oficial y transporte stdio. Expone consultas y altas, modificaciones y bajas de los cuatro componentes; incluye los seis flujos de la entrega. Las reglas permanecen en los servicios REST.

```sh
mvn package
java -jar target/donatrack-mcp.jar
```

Configurar en Claude Desktop `mcpServers.donatrack` con `command` igual a la ruta de Java 21, `args` igual a `["-jar", "RUTA_ABSOLUTA/target/donatrack-mcp.jar"]` y `env` con `DONACIONES_API_URL`, `DONADORES_API_URL`, `LOGISTICA_API_URL`, `INCENTIVOS_API_URL`. Por defecto usa localhost:8081–8084. Reiniciar Claude tras editar su configuración. El stdout se reserva para JSON-RPC; diagnósticos van a stderr.

`python scripts/probar_stdio.py` prueba inicialización, listado, una consulta HTTP y errores de argumentos con un servidor local. No requiere Claude ni credenciales.

Para generar la configuración de Claude con rutas absolutas verificadas:

```sh
python scripts/crear_config_claude.py --java "RUTA_ABSOLUTA_A_JAVA_21"
```

El archivo queda en `target/claude-desktop.config.json`. En Windows, agregar su entrada `donatrack` a `mcpServers` en `%APPDATA%/Claude/claude_desktop_config.json`, conservando las demás entradas existentes. También se pueden indicar las URLs con `--donaciones`, `--donadores`, `--logistica` y `--incentivos`. Las cuatro APIs deben estar disponibles en esas URLs. Reiniciar Claude Desktop, comprobar que aparecen las herramientas de DonaTrack y pedirle que consulte la salud de los cuatro componentes y liste productos. Si falla, revisar `%APPDATA%/Claude/logs`.

Desde TPA, `python testing/local/probar_integracion_mcp.py` ejecuta los seis flujos por `tools/call` contra las cuatro APIs reales con bases H2 aisladas. Primero compilar los cuatro componentes y este módulo. Incluye quejas, revocación de categoría, stock y entrega recurrente en lote. Los callbacks del worker se simulan por HTTP; no valida RabbitMQ ni la interfaz de Claude Desktop. Los resultados y logs quedan en `tmp/revision-entrega5/integracion-mcp`.

La compatibilidad del servidor se verifica por protocolo stdio. La conexión en Claude Desktop se considera comprobada cuando ese cliente muestra las herramientas y ejecuta una consulta correctamente.

Configuración oficial del cliente: [servidores MCP locales en Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

No se exponen endpoints de limpieza administrativa. Las herramientas que modifican datos realizan llamadas reales a las URLs configuradas.

Referencia: https://java.sdk.modelcontextprotocol.io/v0.18.4/server/
