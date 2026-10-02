package ar.edu.utn.dds.mcp;

import com.fasterxml.jackson.databind.*;
import io.modelcontextprotocol.server.*;
import io.modelcontextprotocol.server.transport.StdioServerTransportProvider;
import io.modelcontextprotocol.spec.McpSchema;
import java.util.*;
import java.util.concurrent.CountDownLatch;

public class McpApplication {
  public static void main(String[] args) throws Exception {
    // stdout is reserved exclusively for MCP JSON-RPC; diagnostics go to stderr.
    System.setProperty("org.slf4j.simpleLogger.logFile", "System.err");
    var mapper = new ObjectMapper();
    var gateway = new ApiGateway(Map.of(
        "donaciones", url("DONACIONES_API_URL", "http://localhost:8081"),
        "donadores", url("DONADORES_API_URL", "http://localhost:8082"),
        "logistica", url("LOGISTICA_API_URL", "http://localhost:8083"),
        "incentivos", url("INCENTIVOS_API_URL", "http://localhost:8084")));
    JsonNode catalog;
    try (var stream = McpApplication.class.getResourceAsStream("/tools.json")) {
      catalog = mapper.readTree(Objects.requireNonNull(stream, "Falta tools.json"));
    }
    var server = McpServer.sync(new StdioServerTransportProvider(new io.modelcontextprotocol.json.jackson2.JacksonMcpJsonMapper(mapper)))
        .serverInfo("donatrack", "1.0.0")
        .capabilities(McpSchema.ServerCapabilities.builder().tools(false).build())
        .build();
    for (JsonNode operation : catalog) {
      var tool = McpSchema.Tool.builder().name(operation.path("name").asText())
          .description(operation.path("description").asText())
          .inputSchema(mapper.treeToValue(operation.get("schema"), McpSchema.JsonSchema.class)).build();
      server.addTool(McpServerFeatures.SyncToolSpecification.builder().tool(tool)
          .callHandler((exchange, request) -> {
            try {
              return McpSchema.CallToolResult.builder().content(List.of(
                  new McpSchema.TextContent(gateway.execute(operation, request.arguments())))).isError(false).build();
            } catch (Exception ex) {
              return McpSchema.CallToolResult.builder().content(List.of(
                  new McpSchema.TextContent(ex.getMessage() == null ? "No se pudo completar la operación" : ex.getMessage())))
                  .isError(true).build();
            }
          }).build());
    }
    System.err.printf("DonaTrack MCP listo: %d herramientas%n", catalog.size());
    Runtime.getRuntime().addShutdownHook(new Thread(server::close));
    new CountDownLatch(1).await();
  }
  private static String url(String name, String fallback) {
    String value = System.getenv(name); return value == null || value.isBlank() ? fallback : value;
  }
}
