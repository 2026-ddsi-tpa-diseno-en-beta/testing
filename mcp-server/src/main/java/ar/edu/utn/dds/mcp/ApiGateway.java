package ar.edu.utn.dds.mcp;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;

/** Transport adapter. All business decisions remain in DonaTrack's APIs. */
public class ApiGateway {
  private final Map<String, String> urls;
  private final HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
  private final ObjectMapper mapper = new ObjectMapper();
  public ApiGateway(Map<String, String> urls) {
    this.urls = Map.copyOf(urls);
    for (String url : urls.values()) {
      URI uri = URI.create(url);
      if (!Set.of("http", "https").contains(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null)
        throw new IllegalArgumentException("La URL de servicio debe ser HTTP(S) sin credenciales");
    }
  }
  public String execute(JsonNode operation, Map<String, Object> arguments) throws Exception {
    validate(operation.path("schema"), mapper.valueToTree(arguments), "argumentos");
    String base = urls.get(operation.path("component").asText());
    if (base == null) throw new IllegalArgumentException("Componente sin URL configurada");
    String path = operation.path("path").asText();
    if (path.contains("{id}")) path = path.replace("{id}", encode(arguments.get("id").toString()));
    String method = operation.path("method").asText();
    String trace = UUID.randomUUID().toString();
    var request = HttpRequest.newBuilder(URI.create(base.replaceAll("/+$", "") + path))
        .timeout(Duration.ofSeconds(180)).header("Accept", "application/json").header("X-Trace-Id", trace);
    var body = arguments.get("datos");
    if (body == null) request.method(method, HttpRequest.BodyPublishers.noBody());
    else request.header("Content-Type", "application/json").method(method,
        HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(body), StandardCharsets.UTF_8));
    HttpResponse<String> response;
    try { response = client.send(request.build(), HttpResponse.BodyHandlers.ofString()); }
    catch (InterruptedException ex) { Thread.currentThread().interrupt(); throw ex; }
    boolean success = response.statusCode() >= 200 && response.statusCode() < 300;
    System.err.printf("mcp.operacion tool=%s component=%s status=%d trace=%s%n",
        operation.path("name").asText(), operation.path("component").asText(), response.statusCode(), trace);
    Map<String, Object> result = new LinkedHashMap<>();
    result.put("status", response.statusCode()); result.put("traceId", trace);
    String content = response.body();
    if (content.isBlank()) result.put("resultado", null);
    else { try { result.put("resultado", mapper.readTree(content)); } catch (Exception ex) { result.put("resultado", content); } }
    String json = mapper.writeValueAsString(result);
    if (!success) throw new ApiFailure(json);
    return json;
  }
  private static String encode(String value) {
    if (value.equals(".") || value.equals("..") || value.contains("/") || value.contains("\\"))
      throw new IllegalArgumentException("ID inválido");
    return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
  }
  /** Validate the declared interface schema, never duplicate domain rules. */
  static void validate(JsonNode schema, JsonNode value, String path) {
    String type = schema.path("type").asText();
    boolean valid = switch (type) {
      case "object" -> value.isObject(); case "string" -> value.isTextual();
      case "integer" -> value.isIntegralNumber(); case "boolean" -> value.isBoolean();
      case "array" -> value.isArray();
      default -> true;
    };
    if (!valid) throw new IllegalArgumentException(path + ": se esperaba " + type);
    if (schema.has("enum")) {
      boolean found = false;
      for (JsonNode option : schema.get("enum")) if (option.equals(value)) found = true;
      if (!found) throw new IllegalArgumentException(path + ": valor fuera de las opciones permitidas");
    }
    if (value.isTextual() && value.asText().isBlank()) throw new IllegalArgumentException(path + ": valor obligatorio");
    if (value.isArray() && schema.has("items"))
      for (JsonNode item : value) validate(schema.get("items"), item, path + "[]");
    if (value.isObject()) {
      for (JsonNode required : schema.path("required"))
        if (!value.hasNonNull(required.asText())) throw new IllegalArgumentException(path + ": falta " + required.asText());
      value.fields().forEachRemaining(entry -> {
        JsonNode field = schema.path("properties").get(entry.getKey());
        if (field == null && !schema.path("additionalProperties").asBoolean(true))
          throw new IllegalArgumentException(path + ": parámetro desconocido " + entry.getKey());
        if (field != null && !entry.getValue().isNull()) validate(field, entry.getValue(), path + "." + entry.getKey());
      });
    }
  }
  public static class ApiFailure extends RuntimeException { public ApiFailure(String message) { super(message); } }
}
