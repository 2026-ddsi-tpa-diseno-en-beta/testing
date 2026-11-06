"""Exercise six MCP/gateway flows and failure recovery using fresh local H2 processes.

No RabbitMQ, MongoDB, Telegram or email connection is started. Worker callbacks are
simulated explicitly. A loopback proxy fails one donation acceptance after the real
Donadores API has committed the delivery. Existing services/ports are never reused.
"""
from pathlib import Path
import argparse,json,os,socket,subprocess,sys,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.request import Request,urlopen
from urllib.error import HTTPError

DEFAULT_ROOT=Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-root',type=Path,default=DEFAULT_ROOT)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    root=args.build_root.resolve()
    output=args.output or root/'tmp'/('regresiones-'+time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True,exist_ok=True)
    sys.path.insert(0,str(root/'testing/local'))
    import probar_integracion as suite
    import probar_integracion_mcp as mcp
    suite.ROOT=root
    direct=suite.request
    original_flows=suite.run_flows
    for key in list(os.environ):
        if (key.startswith(('SPRING_','URL_','JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS'))
            or key.endswith('_URL') or any(s in key for s in ['RABBIT','SMTP','TELEGRAM','BETTERSTACK','DATADOG','GRAFANA'])):
            os.environ.pop(key,None)
    os.environ.update(READ_MODEL_PUBLISHER_ENABLED='false',READ_MODEL_MESSAGING_ENABLED='false',LOGISTICA_MESSAGING_ENABLED='false')
    java=os.environ.get('JAVA_EXE','java')
    fail_acceptance=threading.Event()
    class Proxy(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def forward(self):
            if self.command=='PATCH' and '/estado' in self.path and fail_acceptance.is_set():
                fail_acceptance.clear();self.send_response(503);self.end_headers();return
            body=self.rfile.read(int(self.headers.get('Content-Length',0))) or None
            headers={key:value for key,value in self.headers.items() if key.lower() not in ['host','content-length','connection']}
            request=Request('http://127.0.0.1:8081'+self.path,data=body,headers=headers,method=self.command)
            try:
                response=urlopen(request,timeout=20)
            except HTTPError as ex:response=ex
            with response:
                raw=response.read();self.send_response(response.code)
                self.send_header('Content-Type',response.headers.get('Content-Type','application/json'))
                self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        do_GET=do_POST=do_PATCH=do_PUT=do_DELETE=forward

    def regressions():
        invalid=dict(nombre='',apellido='',edad=-5,email='invalido',nroDocumento='',domicilio='')
        direct('donadores','POST','/donadores',invalid,400)
        donor=direct('donadores','POST','/donadores',dict(nombre='Regresión',apellido='Local',edad=25,email='local@example.com',nroDocumento='regresion',domicilio='Medrano'))['id']
        direct('incentivos','GET',f'/insignias/donador/{donor}',expected_status=404)
        direct('incentivos','GET',f'/misiones/donador/{donor}',expected_status=404)
        stats=direct('donadores','GET',f'/donadores/{donor}/estadisticas')
        assert stats['insigniasID']==[] and stats['misionActualID'] is None
        direct('donadores','POST',f'/donadores/{donor}/quejas',dict(donacionID='NO-EXISTE',descripcion='Inválida',fecha='2026-11-06'),404)
        assert direct('donadores','GET',f'/donadores/{donor}')['estado']=='VERIFICADO'
        entity=direct('donadores','POST','/entidades',dict(razonSocial='Regresión',domicilio='Medrano',telefono='123',correo='local@example.com'))['id']
        depot=direct('logistica','POST','/depositos',dict(nombre='Regresión',direccion='Medrano',capacidadMaxima=100))['id']
        direct('logistica','PATCH',f'/depositos/{depot}/algoritmo',dict(algoritmo='SUB_ATENDIDOS'))
        category=direct('donaciones','POST','/categorias',dict(nombre='Regresión',descripcion='Local'))['id']
        sub=direct('donaciones','POST','/categorias',dict(nombre='Regresión Sub',descripcion='Local',categoriaPadreID=category))['id']
        def product(name):
            return direct('donaciones','POST','/productos',dict(nombre=name,descripcion='Producto de regresión',categoriaID=category,subcategoriaID=sub))['id']
        def need(p,qty,kind='EXTRAORDINARIA'):
            return direct('donadores','POST','/necesidades',dict(entidadID=entity,productoSolicitadoID=p,descripcion='Regresión',cantidadObjetivo=qty,nivelDeUrgencia=9,tipo=kind))['id']
        def donate(p,qty,n=None):
            donation=direct('donaciones','POST','/donaciones',dict(donadorID=donor,depositoID=depot,productoID=p,cantidad=qty,descripcion='Regresión'))['id']
            pack=next(v for v in direct('logistica','GET',f'/depositos/{depot}')['stockActual'] if v['donacionID']==donation)['id']
            direct('logistica','POST','/internal/matchmaking/resultados',dict(depositoId=depot,paqueteId=pack,necesidadId=n,cantidadAsignada=qty if n else 0,cantidadSobrante=0 if n else qty))
            return donation,pack
        p=product('Entrega de prueba');n=need(p,30);donation,pack=donate(p,3,n)
        direct('donadores','DELETE',f'/necesidades/{n}',expected_status=409)
        direct('donadores','DELETE',f'/entidades/{entity}',expected_status=409)
        fail_acceptance.set();direct('logistica','POST','/entregas',dict(id=pack),502)
        assert direct('donadores','GET',f'/necesidades/{n}')['cantidadAsignada']==3
        direct('logistica','POST','/entregas',dict(id=pack))
        assert direct('donadores','GET',f'/necesidades/{n}')['cantidadAsignada']==3
        assert direct('donaciones','GET',f'/donaciones/{donation}')['estado']=='ACEPTADA'
        complaint=dict(donacionID=donation,descripcion='Queja válida',fecha='2026-11-06')
        first=direct('donadores','POST',f'/donadores/{donor}/quejas',complaint)
        second=direct('donadores','POST',f'/donadores/{donor}/quejas',complaint)
        assert first['id']==second['id']
        assert len(direct('donadores','GET',f'/donadores/{donor}/quejas'))==1
        # Complete the ordinary public complaint flow after the duplicate internal receipt.
        direct('donaciones','POST',f'/donaciones/{donation}/quejas',dict(descripcion='Queja válida'))
        assert len(direct('donadores','GET',f'/donadores/{donor}/quejas'))==1
        b=product('Lote recurrente');donate(b,4);donate(b,6);recurring=need(b,10,'RECURRENTE')
        batch=[a['paqueteID'] for a in direct('logistica','GET','/asignaciones') if a['necesidadID']==recurring]
        assert len(batch)==2
        fail_acceptance.set();direct('logistica','POST','/entregas/lote',dict(paqueteIds=batch),502)
        assert direct('donadores','GET',f'/necesidades/{recurring}')['cantidadAsignada']==10
        direct('logistica','POST','/entregas/lote',dict(paqueteIds=list(reversed(batch))))
        assert direct('donadores','GET',f'/necesidades/{recurring}')['cantidadAsignada']==10
        print('PASS validaciones, quejas, bajas y recuperación de entrega individual/lote entre APIs H2',flush=True)
        return dict(validacion=True,quejasIdempotentes=True,bajasProtegidas=True,entregaIndividual=3,loteRecurrente=10,
            falloInyectado='HTTP503 de Donaciones después del commit de satisfacción de Donadores')

    def flows():
        result=original_flows();result['regresiones']=regressions();return result
    suite.run_flows=flows
    actual_client=mcp.McpClient
    mcp.McpClient=lambda gateway=None:actual_client(gateway='http://127.0.0.1:18080')

    def launch():
        suite.OUTPUT=output
        for port in [8081,8082,8083,8084,18080,18081]:
            with socket.socket() as sock:
                if sock.connect_ex(('127.0.0.1',port))==0:raise RuntimeError(f'Puerto {port} ocupado: no se reutiliza ni modifica el servicio existente')
        processes=[];streams=[];proxy=ThreadingHTTPServer(('127.0.0.1',18081),Proxy)
        threading.Thread(target=proxy.serve_forever,daemon=True).start()
        try:
            configdir=output/'config';configdir.mkdir(exist_ok=True)
            for repo,component,port in suite.SERVICES:
                jars=[p for p in (root/repo/'target').glob('*.jar') if not any(s in p.name for s in ['worker','original','sources'])]
                if len(jars)!=1:raise RuntimeError('Compilar primero '+repo)
                config=(root/'testing/local'/f'{component}.properties').read_text(encoding='utf-8')
                if component=='logistica':config=config.replace('integrations.donaciones-url=http://localhost:8081','integrations.donaciones-url=http://127.0.0.1:18081')
                cfg=configdir/f'{component}.properties';cfg.write_text(config,encoding='utf-8')
                stream=(output/f'{component}.log').open('w',encoding='utf-8');streams.append(stream)
                processes.append(subprocess.Popen([java,'-Xmx256m','-jar',str(jars[0]),'--spring.config.location=file:'+cfg.resolve().as_posix()],
                    cwd=root,stdout=stream,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)))
            env=os.environ.copy()
            for key,port in [('DONACIONES_URL',8081),('DONADORES_ENTIDADES_URL',8082),('LOGISTICA_URL',8083),('INCENTIVOS_URL',8084),('CONSULTAS_URL',18085)]:env[key]=f'http://127.0.0.1:{port}'
            stream=(output/'gateway.log').open('w',encoding='utf-8');streams.append(stream)
            jars=list((root/'API_Gateway/target').glob('*.jar'));jars=[p for p in jars if 'original' not in p.name]
            if len(jars)!=1:raise RuntimeError('Compilar gateway primero')
            processes.append(subprocess.Popen([java,'-Xmx192m','-jar',str(jars[0]),'--server.port=18080'],env=env,
                stdout=stream,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)))
            deadline=time.monotonic()+180;remaining={c for _,c,_ in suite.SERVICES}|{'gateway'}
            while remaining and time.monotonic()<deadline:
                if any(p.poll() is not None for p in processes):raise RuntimeError('Falló arranque; revisar logs de '+str(output))
                for c in list(remaining):
                    try:
                        if c=='gateway':
                            with urlopen('http://127.0.0.1:18080/actuator/health',timeout=2) as response:ok=response.status==200
                        else:ok=direct(c,'GET','/actuator/health')['status']=='UP'
                        if ok:remaining.remove(c)
                    except Exception:pass
                time.sleep(1)
            if remaining:raise RuntimeError('No iniciaron: '+str(remaining))
            result=suite.run_flows();result.update(gatewayRealLocal=True,broker='callbacks HTTP simulados',bases='H2 efímeras',mongo=False)
            (output/'resultado.json').write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
        finally:
            for p in processes:
                if p.poll() is None:p.terminate()
            for p in processes:
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:p.kill();p.wait(timeout=10)
            proxy.shutdown();proxy.server_close()
            for s in streams:s.close()
    suite.main=launch
    mcp.main()

if __name__=='__main__':main()
