"""Run all six REST flows against four isolated H2 services, never cloud databases.

Build each service first with mvn package. Requires Python 3 and Java 21 on PATH.
RabbitMQ is disabled in these configs; callbacks simulate the worker's HTTP contract.
This verifies REST/domain integration, not delivery through the real message broker.
"""
from pathlib import Path
import json, os, re, subprocess, time, urllib.request, urllib.error

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'tmp/revision-entrega5/integracion-local'
SERVICES = [('donaciones', 'donaciones', 8081), ('Donadores-Y-Entidades', 'donadores', 8082),
            ('Componente_Logistica', 'logistica', 8083), ('Incentivos', 'incentivos', 8084)]

def request(component, method, path, data=None, expected_status=None):
    port = dict((c, p) for _, c, p in SERVICES)[component]
    raw = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=raw, method=method,
        headers={'Content-Type': 'application/json', 'X-Trace-Id': 'prueba-integrada-local'})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            if expected_status is not None:
                assert response.status == expected_status, (component, path, response.status)
            body = response.read().decode()
            return json.loads(body) if body and 'json' in response.headers.get('Content-Type','') else body
    except urllib.error.HTTPError as ex:
        if ex.code == expected_status:
            return json.loads(ex.read().decode())
        raise AssertionError(f'{component} {method} {path}: HTTP {ex.code} {ex.read().decode()}') from ex

def run_flows():
    donor = request('donadores','POST','/donadores',dict(nombre='Demo',apellido='Local',edad=25,email='demo@example.com',nroDocumento='123',domicilio='Medrano'))['id']
    entity = request('donadores','POST','/entidades',dict(razonSocial='Escuela local',domicilio='Medrano',telefono='123',correo='escuela@example.com'))['id']
    depot = request('logistica','POST','/depositos',dict(nombre='Deposito local',direccion='Medrano',capacidadMaxima=1000))['id']
    request('logistica','PATCH',f'/depositos/{depot}/algoritmo',dict(algoritmo='SUB_ATENDIDOS'))
    products=[]
    for n in range(3):
        cat=request('donaciones','POST','/categorias',dict(nombre=f'Categoria {n}',descripcion='Categoria de prueba'))['id']
        sub=request('donaciones','POST','/categorias',dict(nombre=f'Subcategoria {n}',descripcion='Subcategoria de prueba',categoriaPadreID=cat))['id']
        products.append(request('donaciones','POST','/productos',dict(nombre=f'Producto {n}',descripcion='Producto de prueba local',categoriaID=cat,subcategoriaID=sub))['id'])
    def need(product, quantity, kind='EXTRAORDINARIA'):
        return request('donadores','POST','/necesidades',dict(entidadID=entity,productoSolicitadoID=product,descripcion='Necesidad de prueba',cantidadObjetivo=quantity,nivelDeUrgencia=5,tipo=kind))
    def donate(product, quantity, necessity=None):
        donation=request('donaciones','POST','/donaciones',dict(donadorID=donor,depositoID=depot,productoID=product,cantidad=quantity,descripcion='Donacion local'))
        stock=request('logistica','GET',f'/depositos/{depot}')['stockActual']
        pack=next(p for p in stock if p['donacionID']==donation['id'])
        request('logistica','POST','/internal/matchmaking/resultados',dict(depositoId=depot,paqueteId=pack['id'],necesidadId=necessity,cantidadAsignada=quantity if necessity else 0,cantidadSobrante=0 if necessity else quantity))
        return donation['id'],pack['id']
    original_need=need(products[0],100)['id']
    donation,pack=donate(products[0],10,original_need)
    request('logistica','POST','/entregas',dict(id=pack))
    assert request('donaciones','GET',f'/donaciones/{donation}')['estado']=='ACEPTADA'
    assert request('donadores','GET',f'/necesidades/{original_need}')['cantidadAsignada']==10
    request('donaciones','POST',f'/donaciones/{donation}/quejas',dict(descripcion='Producto defectuoso'))
    assert request('donaciones','GET',f'/donaciones/{donation}')['estado']=='CONQUEJA'
    print('PASS realizar donacion, reportar entrega, registrar queja',flush=True)
    accepted=[]
    for _ in range(20):
        d,p=donate(products[0],1,original_need);request('logistica','POST','/entregas',dict(id=p));accepted.append(d)
    donate(products[1],4);donate(products[1],6);donate(products[2],3)
    def mission(name,kind,start,end):
        badge=request('incentivos','POST','/insignias',dict(nombre=name,descripcion='Premio local'))['id']
        mid=request('incentivos','POST','/misiones',dict(nombre=name,insigniaID=badge,categoriaInicio=start,categoriaFin=end,tipo=kind))['id']
        request('incentivos','POST',f'/misiones/donador/{donor}',dict(id=mid))
        request('incentivos','POST',f'/procesamiento/{donor}')
        return badge
    mission('Completitud','COMPLETITUD','OCASIONAL','COLABORADOR')
    mission('Exitosas','DONACIONES_EXITOSAS','COLABORADOR','TRANSFORMADOR')
    stats=request('donadores','GET',f'/donadores/{donor}/estadisticas')
    assert stats['categoria']=='TRANSFORMADOR',stats
    request('donaciones','POST',f'/donaciones/{accepted[0]}/quejas',dict(descripcion='Queja que revoca exitosas'))
    request('incentivos','POST',f'/procesamiento/{donor}')
    assert request('donadores','GET',f'/donadores/{donor}/estadisticas')['categoria']=='COLABORADOR'
    assert len(request('incentivos','GET',f'/insignias/donador/{donor}'))==1
    print('PASS procesar donador, estadisticas y revocacion por queja',flush=True)
    recurring=need(products[1],10,'RECURRENTE')
    assert recurring['cantidadAsignada']==0
    assignments=[a for a in request('logistica','GET','/asignaciones') if a['necesidadID']==recurring['id']]
    assert len(assignments)==2,assignments
    assert all(a['origen']=='SOLICITUD_ENTIDAD' for a in assignments)
    request('logistica','POST','/entregas/lote',dict(paqueteIds=[a['paqueteID'] for a in assignments]))
    assert request('donadores','GET',f"/necesidades/{recurring['id']}")['cantidadAsignada']==10
    assert request('logistica','GET',f'/stock/{products[1]}')['cantidadDisponible']==0
    print('PASS nueva necesidad, reserva de stock y entrega recurrente en lote',flush=True)
    assert len(request('donadores','GET','/necesidades'))==2
    for _,component,_ in SERVICES:
        metrics=request(component,'GET','/actuator/prometheus')
        assert 'http_server_requests_seconds' in metrics,(component,metrics[:200])
        if component == 'donadores':
            for meter, expected in [('donadores_necesidades_registradas_total', 2),
                                    ('donadores_necesidades_unidades_entregadas_total', 40)]:
                found = re.search(r'^' + meter + r'(?:\{[^}]*\})? ([0-9.eE+-]+)', metrics, re.MULTILINE)
                assert found and float(found.group(1)) == expected, (meter, expected)
        spec=request(component,'GET','/v3/api-docs')
        assert spec.get('paths'),component
        (OUTPUT/f'{component}-openapi.json').write_text(json.dumps(spec,indent=2,ensure_ascii=False),encoding='utf-8')
    request('logistica','GET','/depositos/id-invalido',expected_status=400)
    request('incentivos','GET','/misiones/inexistente',expected_status=404)
    request('incentivos','GET','/insignias/inexistente',expected_status=404)
    request('donadores','POST','/necesidades?periodo=INVALIDO',{},expected_status=400)
    print('PASS metricas Prometheus y OpenAPI de los cuatro componentes',flush=True)
    return {'flujos':6,'revocacion':True,'stock_lote_recurrente':True,'openapi':4,'prometheus':4,'broker':'simulado mediante callback HTTP'}

def main():
    OUTPUT.mkdir(parents=True,exist_ok=True)
    java=os.environ.get('JAVA_EXE','java')
    processes=[]; streams=[]
    env=os.environ.copy()
    for key in ['BETTERSTACK_SOURCE_TOKEN','BETTERSTACK_INGEST_URL','JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS']:
        env.pop(key,None)
    try:
        # Refuse to connect to pre-existing services. These tests mutate only the subprocess H2 databases.
        import socket
        for _,_,port in SERVICES:
            with socket.socket() as sock:
                if sock.connect_ex(('127.0.0.1',port))==0: raise RuntimeError(f'Puerto {port} ocupado. No se ejecutaron pruebas.')
        for repo,component,port in SERVICES:
            jars=[p for p in (ROOT/repo/'target').glob('*.jar') if not any(s in p.name for s in ['worker','original','sources'])]
            if len(jars)!=1: raise RuntimeError(f'Compilar primero {repo}: mvn package')
            config=(ROOT/'testing/local'/f'{component}.properties').as_posix()
            stream=(OUTPUT/f'{component}.log').open('w',encoding='utf-8');streams.append(stream)
            process=subprocess.Popen([java,'-jar',str(jars[0]),f'--spring.config.location=file:{config}'],
                cwd=ROOT,env=env,stdout=stream,stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            processes.append(process)
        deadline=time.monotonic()+120
        remaining=set(c for _,c,_ in SERVICES)
        while remaining and time.monotonic()<deadline:
            if any(p.poll() is not None for p in processes): raise RuntimeError('Un servicio no pudo iniciar; revisar logs locales')
            for component in list(remaining):
                try:
                    if request(component,'GET','/actuator/health').get('status')=='UP': remaining.remove(component)
                except Exception: pass
            time.sleep(1)
        if remaining: raise RuntimeError('No iniciaron: '+', '.join(sorted(remaining)))
        initial_metrics=request('donaciones','GET','/actuator/prometheus')
        assert 'donatrack_donaciones_registradas_total' in initial_metrics
        assert 'donatrack_donaciones_rechazadas_total' in initial_metrics
        result=run_flows();(OUTPUT/'resultado.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    finally:
        for process in processes:
            if process.poll() is None: process.terminate()
        for process in processes:
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill();process.wait(timeout=10)
        for stream in streams: stream.close()

if __name__=='__main__': main()
