# DonaTrack MCP

Módulo Java 21 independiente con SDK MCP oficial y transporte stdio. Expone consultas y altas, modificaciones y bajas de los cuatro componentes; incluye los seis flujos de la entrega. Las reglas permanecen en los servicios REST.

```sh
mvn package
java -jar target/donatrack-mcp.jar
```

Configurar en Claude Desktop `mcpServers.donatrack` con `command` igual a la ruta de Java 21, `args` igual a `["-jar", "RUTA_ABSOLUTA/target/donatrack-mcp.jar"]` y `env` con `DONACIONES_API_URL`, `DONADORES_API_URL`, `LOGISTICA_API_URL`, `INCENTIVOS_API_URL`. Por defecto usa localhost:8081–8084. Reiniciar Claude tras editar su configuración. El stdout se reserva para JSON-RPC; diagnósticos van a stderr.

`python scripts/probar_stdio.py` prueba inicialización, listado, una consulta HTTP y errores de argumentos con un servidor local. No requiere Claude ni credenciales.

No se exponen endpoints de limpieza administrativa. Las herramientas que modifican datos realizan llamadas reales a las URLs configuradas.

Referencia: https://java.sdk.modelcontextprotocol.io/v0.18.4/server/
