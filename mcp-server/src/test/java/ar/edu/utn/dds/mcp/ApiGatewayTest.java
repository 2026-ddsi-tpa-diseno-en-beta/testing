package ar.edu.utn.dds.mcp;

import com.fasterxml.jackson.databind.*;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import static org.junit.jupiter.api.Assertions.*;

class ApiGatewayTest {
  final ObjectMapper mapper=new ObjectMapper();
  JsonNode catalog;
  @BeforeEach void load() throws Exception {
    catalog=mapper.readTree(getClass().getResourceAsStream("/tools.json"));
  }
  JsonNode tool(String name) {
    for (JsonNode item:catalog) if(item.path("name").asText().equals(name)) return item;
    throw new IllegalArgumentException(name);
  }
  @Test void catalogCoversFourComponentsAndSixFlowsWithoutAdminWipes() {
    Set<String> names=new HashSet<>(), components=new HashSet<>();
    for(JsonNode operation:catalog) {
      assertTrue(names.add(operation.path("name").asText()));
      components.add(operation.path("component").asText());
      assertFalse(operation.path("path").asText().contains("/admin"));
    }
    assertEquals(Set.of("donaciones","donadores","logistica","incentivos"),components);
    assertTrue(names.containsAll(List.of("realizar_donacion","reportar_entrega","registrar_queja","procesar_donador","crear_necesidad","estadisticas_donador")));
  }
  @Test void requiredInputsAreRejectedBeforeAnyNetworkCall() {
    var gateway=new ApiGateway(Map.of("donaciones","http://localhost:1"));
    assertThrows(IllegalArgumentException.class,()->gateway.execute(tool("realizar_donacion"),Map.of("datos",Map.of("cantidad",3))));
  }
  @Test void idsCannotChangeTheApiRoute() {
    var gateway=new ApiGateway(Map.of("donaciones","http://localhost:1"));
    assertThrows(IllegalArgumentException.class,()->gateway.execute(tool("buscar_producto"),Map.of("id","../admin")));
  }
  @Test void sendsOriginalBodyAndTraceToTheCorrectComponent() throws Exception {
    HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
    AtomicReference<String> body=new AtomicReference<>(), trace=new AtomicReference<>();
    server.createContext("/donaciones",exchange->{
      body.set(new String(exchange.getRequestBody().readAllBytes(),StandardCharsets.UTF_8));
      trace.set(exchange.getRequestHeaders().getFirst("X-Trace-Id"));
      byte[] output="{\"id\":\"nueva\"}".getBytes(StandardCharsets.UTF_8);
      exchange.sendResponseHeaders(201,output.length); exchange.getResponseBody().write(output); exchange.close();
    });
    server.start();
    try {
      var gateway=new ApiGateway(Map.of("donaciones","http://127.0.0.1:"+server.getAddress().getPort()));
      var data=Map.of("donadorID","d","depositoID","dep","productoID","p","descripcion","Donación","cantidad",3);
      var response=mapper.readTree(gateway.execute(tool("realizar_donacion"),Map.of("datos",data)));
      assertEquals(mapper.valueToTree(data),mapper.readTree(body.get()));
      assertEquals("nueva",response.path("resultado").path("id").asText());
      assertEquals(trace.get(),response.path("traceId").asText());
    } finally { server.stop(0); }
  }
  @Test void remoteFailuresRemainFailures() throws Exception {
    HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
    server.createContext("/productos/p",exchange->{exchange.sendResponseHeaders(503,-1);exchange.close();}); server.start();
    try {
      var gateway=new ApiGateway(Map.of("donaciones","http://127.0.0.1:"+server.getAddress().getPort()));
      assertThrows(ApiGateway.ApiFailure.class,()->gateway.execute(tool("buscar_producto"),Map.of("id","p")));
    } finally { server.stop(0); }
  }
}
