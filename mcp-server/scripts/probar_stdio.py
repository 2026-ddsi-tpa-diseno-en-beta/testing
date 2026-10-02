"""Smoke test of the packaged MCP over stdio, using a local HTTP stub."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, os, queue, subprocess, threading

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == '/actuator/health'
        assert self.headers.get('X-Trace-Id')
        body=b'{"status":"UP"}'
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass

def main():
    root=Path(__file__).resolve().parents[1]
    server=ThreadingHTTPServer(('127.0.0.1',0), Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    env=os.environ.copy()
    for key in ['JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS']:
        env.pop(key,None)
    for component in ['DONACIONES','DONADORES','LOGISTICA','INCENTIVOS']:
        env[component+'_API_URL']=f'http://127.0.0.1:{server.server_port}'
    process=subprocess.Popen([env.get('JAVA_EXE','java'),'-jar',str(root/'target/donatrack-mcp.jar')],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
        encoding='utf-8',env=env,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    messages=queue.Queue()
    def receive():
        for line in process.stdout:
            try: messages.put(json.loads(line))
            except Exception as ex: messages.put(ex)
    threading.Thread(target=receive,daemon=True).start()
    def send(value):
        process.stdin.write(json.dumps(value)+'\n');process.stdin.flush()
    def call(id,method,params):
        send(dict(jsonrpc='2.0',id=id,method=method,params=params))
        while True:
            response=messages.get(timeout=20)
            if isinstance(response,Exception):raise response
            if response.get('id')==id:
                assert 'error' not in response,response
                return response['result']
    try:
        result=call(1,'initialize',dict(protocolVersion='2025-06-18',capabilities={},clientInfo=dict(name='prueba-local',version='1')))
        assert result['serverInfo']['name']=='donatrack',result
        send(dict(jsonrpc='2.0',method='notifications/initialized'))
        tools=call(2,'tools/list',{})['tools']
        assert len(tools)==len(json.loads((root/'src/main/resources/tools.json').read_text(encoding='utf-8')))
        result=call(3,'tools/call',dict(name='salud_donaciones',arguments={}))
        assert not result.get('isError'),result
        assert json.loads(result['content'][0]['text'])['resultado']['status']=='UP'
        result=call(4,'tools/call',dict(name='realizar_donacion',arguments={}))
        assert result.get('isError'),result
        print(f'PASS MCP stdio: initialize, {len(tools)} herramientas, consulta HTTP y error de argumentos')
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        server.shutdown();server.server_close()

if __name__=='__main__':main()
