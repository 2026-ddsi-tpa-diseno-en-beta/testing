"""Run the six business flows through MCP stdio against isolated local services.

Reuses the REST suite's assertions and H2 lifecycle. Worker callbacks and
diagnostic endpoints still use HTTP; every business operation uses tools/call.
"""
import json
import os
import queue
import re
import subprocess
import threading
import probar_integracion as suite


class McpClient:
    def __init__(self):
        self.sequence = 0
        self.messages = queue.Queue()
        env = os.environ.copy()
        for key in ('JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS'):
            env.pop(key, None)
        for _, component, port in suite.SERVICES:
            env[component.upper() + '_API_URL'] = f'http://127.0.0.1:{port}'
        self.log = (suite.OUTPUT / 'mcp.log').open('w', encoding='utf-8')
        self.process = subprocess.Popen(
            [env.get('JAVA_EXE', 'java'), '-jar',
             str(suite.ROOT / 'testing/mcp-server/target/donatrack-mcp.jar')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, encoding='utf-8', env=env,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        threading.Thread(target=self.receive, daemon=True).start()

    def receive(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except Exception as ex:
                self.messages.put(ex)
        self.messages.put(RuntimeError('MCP cerró stdout; revisar mcp.log'))

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def call(self, method, params):
        self.sequence += 1
        self.send(dict(jsonrpc='2.0', id=self.sequence, method=method, params=params))
        while True:
            response = self.messages.get(timeout=45)
            if isinstance(response, Exception):
                raise response
            if response.get('id') == self.sequence:
                assert 'error' not in response, response
                return response['result']

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def main():
    suite.OUTPUT = suite.ROOT / 'tmp/revision-entrega5/integracion-mcp'
    catalog = json.loads((suite.ROOT / 'testing/contratos/tools.json').read_text(encoding='utf-8'))
    direct_request, original_flows = suite.request, suite.run_flows
    client = None
    used = set()

    def request(component, method, path, data=None, expected_status=None):
        # Explicit HTTP exceptions: readiness, observability, simulated worker,
        # and a REST-only invalid query (not part of the public MCP catalog).
        if client is None or path in ('/actuator/health', '/actuator/prometheus', '/v3/api-docs',
                                      '/internal/matchmaking/resultados', '/necesidades?periodo=INVALIDO'):
            return direct_request(component, method, path, data, expected_status)
        for operation in catalog:
            if operation['component'] != component or operation['method'] != method:
                continue
            pattern = re.escape(operation['path']).replace(re.escape('{id}'), '([^/?]+)')
            match = re.fullmatch(pattern, path)
            if match is None:
                continue
            arguments = {}
            if match.groups():
                arguments['id'] = match.group(1)
            if data is not None:
                arguments['datos'] = data
            result = client.call('tools/call', dict(name=operation['name'], arguments=arguments))
            payload = json.loads(result['content'][0]['text'])
            status = payload['status']
            assert payload['traceId'], payload
            assert bool(result.get('isError')) == (status >= 400), result
            if expected_status is None:
                assert 200 <= status < 300, (operation['name'], payload)
            else:
                assert status == expected_status, (operation['name'], payload)
            used.add(operation['name'])
            return payload['resultado']
        raise AssertionError(f'Falta herramienta MCP para {component} {method} {path}')

    def run_flows():
        nonlocal client
        client = McpClient()
        try:
            initialized = client.call('initialize', dict(protocolVersion='2025-06-18', capabilities={},
                clientInfo=dict(name='integracion-local', version='1')))
            assert initialized['serverInfo']['name'] == 'donatrack', initialized
            client.send(dict(jsonrpc='2.0', method='notifications/initialized'))
            listed = client.call('tools/list', {})['tools']
            assert {tool['name'] for tool in listed} == {tool['name'] for tool in catalog}
            result = original_flows()
            required = {'realizar_donacion', 'reportar_entrega', 'registrar_queja',
                        'procesar_donador', 'crear_necesidad', 'estadisticas_donador'}
            assert required <= used, required - used
            result.update(transporte='MCP stdio', herramientas_probadas=sorted(used),
                          cliente_claude='pendiente de conexión en Claude Desktop')
            print(f'PASS MCP con cuatro APIs reales: {len(used)} herramientas, seis flujos', flush=True)
            return result
        finally:
            client.close()
            client = None

    suite.request, suite.run_flows = request, run_flows
    try:
        suite.main()
    finally:
        suite.request, suite.run_flows = direct_request, original_flows


if __name__ == '__main__':
    main()
