"""Validate six business flows and four CQRS reports through the local gateway.

Requires compose.yaml running. Creates new demo records without deleting existing data.
No callback simulation: RabbitMQ and the workers must assign the donations.
"""
import argparse
import json
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from urllib.parse import urlparse

HERE=Path(__file__).resolve().parent
PREFIX={'donaciones':'donaciones','donadores':'donadores-entidades','logistica':'logistica','incentivos':'incentivos','consultas':'consultas'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gateway', default='http://127.0.0.1:8080')
    parser.add_argument('--mcp', action='store_true', help='Ejecutar las operaciones a través de MCP stdio y gateway')
    parser.add_argument('--timeout', type=int, default=120)
    args=parser.parse_args()
    if urlparse(args.gateway).hostname not in ('localhost','127.0.0.1'):
        parser.error('Este ensayo crea datos y está limitado al entorno local.')
    client=None; used=set()
    catalog=json.loads((HERE.parent/'contratos/tools.json').read_text(encoding='utf-8'))
    def http(component, method, path, data=None):
        body=None if data is None else json.dumps(data).encode()
        req=Request(args.gateway.rstrip('/')+'/api/'+PREFIX[component]+path, data=body, method=method, headers={'Content-Type':'application/json'})
        with urlopen(req,timeout=60) as response:
            content=response.read(); return json.loads(content) if content else None
    def request(component,method,path,data=None):
        if client is None: return http(component,method,path,data)
        import re
        for op in catalog:
            if op['component']!=component or op['method']!=method: continue
            match=re.fullmatch(re.escape(op['path']).replace(re.escape('{id}'),'([^/?]+)'),path)
            if not match: continue
            arguments={}
            if match.groups(): arguments['id']=match.group(1)
            if data is not None: arguments['datos']=data
            result=client.call('tools/call',dict(name=op['name'],arguments=arguments))
            if result.get('isError'): raise AssertionError((op['name'],result))
            used.add(op['name']); return result['structuredContent']['resultado']
        raise AssertionError('Falta herramienta para '+component+' '+method+' '+path)
    def wait(description, action, predicate):
        deadline=time.monotonic()+args.timeout; last=None
        while time.monotonic()<deadline:
            try:
                last=action()
                if predicate(last): return last
            except HTTPError as ex:
                if ex.code not in (404,502,503,504): raise
                last=str(ex)
            time.sleep(0.5)
        raise AssertionError(f'{description}: no convergió; último resultado={last}')
    try:
        wait('gateway y consultas',lambda:http('consultas','GET','/estado'),lambda x:x.get('servicio'))
        if args.mcp:
            sys.path.insert(0,str(HERE.parent/'local'))
            import probar_integracion_mcp as transport
            transport.suite.OUTPUT=HERE/'evidencia.local';transport.suite.OUTPUT.mkdir(exist_ok=True)
            client=transport.McpClient(gateway=args.gateway)
            client.call('initialize',dict(protocolVersion='2025-06-18',capabilities={},clientInfo=dict(name='demo-entrega6',version='1')))
            client.send(dict(jsonrpc='2.0',method='notifications/initialized'))
        tag=str(int(time.time()))
        donor=request('donadores','POST','/donadores',dict(nombre='Ana',apellido='Demo '+tag,edad=25,email='ana@example.com',nroDocumento=tag,domicilio='Medrano'))['id']
        entity=request('donadores','POST','/entidades',dict(razonSocial='Escuela Demo '+tag,domicilio='Medrano',telefono='123',correo='escuela@example.com'))['id']
        depot=request('logistica','POST','/depositos',dict(nombre='Central Demo '+tag,direccion='Medrano',capacidadMaxima=1000))['id']
        request('logistica','PATCH',f'/depositos/{depot}/algoritmo',dict(algoritmo='SUB_ATENDIDOS'))
        products=[]
        for index,name in enumerate(['Alimentos','Abrigo','Educación']):
            category=request('donaciones','POST','/categorias',dict(nombre=name+' '+tag,descripcion='Demo'))['id']
            sub=request('donaciones','POST','/categorias',dict(nombre='Sub '+name+' '+tag,descripcion='Demo',categoriaPadreID=category))['id']
            products.append(request('donaciones','POST','/productos',dict(nombre=['Arroz','Campera','Libro'][index]+' '+tag,descripcion='Demo',categoriaID=category,subcategoriaID=sub))['id'])
        def need(product,quantity,kind='EXTRAORDINARIA'):
            return request('donadores','POST','/necesidades',dict(entidadID=entity,productoSolicitadoID=product,descripcion='Demo '+tag,cantidadObjetivo=quantity,nivelDeUrgencia=9,tipo=kind))['id']
        stock_expected={}
        def donate(product,quantity,necessity=None):
            donation=request('donaciones','POST','/donaciones',dict(donadorID=donor,depositoID=depot,productoID=product,cantidad=quantity,descripcion='Demo '+tag))['id']
            if necessity:
                packages=request('logistica','GET',f'/depositos/{depot}')['stockActual']
                package=next(p for p in packages if p['donacionID']==donation)['id']
                assignments=wait('asignación por workers',lambda:request('logistica','GET','/asignaciones'),lambda values:any(a['paqueteID']==package for a in values))
                assigned=next(a for a in assignments if a['paqueteID']==package)
                assert assigned['necesidadID']==necessity,assigned
                request('logistica','POST','/entregas',dict(id=assigned['paqueteID']))
                assert request('donaciones','GET',f'/donaciones/{donation}')['estado']=='ACEPTADA'
            else:
                stock_expected[product]=stock_expected.get(product,0)+quantity
                wait('stock por workers',lambda:request('logistica','GET',f'/stock/{product}'),lambda d:d['cantidadDisponible']==stock_expected[product])
            return donation
        n=need(products[0],100); donation=donate(products[0],10,n)
        request('donaciones','POST',f'/donaciones/{donation}/quejas',dict(descripcion='Producto defectuoso'))
        assert request('donaciones','GET',f'/donaciones/{donation}')['estado']=='CONQUEJA'
        accepted=[donate(products[0],1,n) for _ in range(20)]
        donate(products[1],4);donate(products[1],6);donate(products[2],3)
        for name,kind,start,end in [('Completitud','COMPLETITUD','OCASIONAL','COLABORADOR'),('Exitosas','DONACIONES_EXITOSAS','COLABORADOR','TRANSFORMADOR')]:
            badge=request('incentivos','POST','/insignias',dict(nombre=name+' '+tag,descripcion='Demo'))['id']
            mission=request('incentivos','POST','/misiones',dict(nombre=name+' '+tag,insigniaID=badge,categoriaInicio=start,categoriaFin=end,tipo=kind))['id']
            request('incentivos','POST',f'/misiones/donador/{donor}',dict(id=mission));request('incentivos','POST',f'/procesamiento/{donor}')
        assert request('donadores','GET',f'/donadores/{donor}/estadisticas')['categoria']=='TRANSFORMADOR'
        request('donaciones','POST',f'/donaciones/{accepted[0]}/quejas',dict(descripcion='Queja que revoca misión'))
        request('incentivos','POST',f'/procesamiento/{donor}')
        assert request('donadores','GET',f'/donadores/{donor}/estadisticas')['categoria']=='COLABORADOR'
        recurring=need(products[1],10,'RECURRENTE')
        assignments=wait('reserva del stock',lambda:request('logistica','GET','/asignaciones'),lambda values:len([a for a in values if a['necesidadID']==recurring])==2)
        batches=[a for a in assignments if a['necesidadID']==recurring]
        assert all(a['origen']=='SOLICITUD_ENTIDAD' for a in batches)
        request('logistica','POST','/entregas/lote',dict(paqueteIds=[a['paqueteID'] for a in batches]))
        assert request('donadores','GET',f'/necesidades/{recurring}')['cantidadAsignada']==10
        donor_report=wait('ficha integral',lambda:request('consultas','GET',f'/donadores/{donor}/ficha'),lambda d:d.get('categoria')=='COLABORADOR' and d.get('cantidadQuejas')==2 and sum(e['unidades'] for e in d.get('entidadesBeneficiadas',[]))==40)
        urgent=wait('necesidades urgentes',lambda:request('consultas','GET','/necesidades/urgentes'),lambda ds:any(d['necesidadID']==n and d['cantidadFaltante']==70 for d in ds))
        depot_report=wait('reporte depósito',lambda:request('consultas','GET','/depositos/reporte'),lambda ds:any(d['depositoID']==depot and d['cantidadEntidadesAtendidas']==1 for d in ds))
        quality=request('consultas','GET','/calidad')
        assert any(d['donadorID']==donor for d in quality['donadoresConMasQuejas'])
        output=HERE/'evidencia.local';output.mkdir(exist_ok=True)
        evidence=dict(gateway=args.gateway,transporte='MCP stdio' if client else 'HTTP',flujos=6,worker='RabbitMQ real, sin callbacks simulados',donadorID=donor,entidadID=entity,depositoID=depot,necesidadID=n,tools=sorted(used),ficha=donor_report,necesidades=urgent,depositos=depot_report,calidad=quality)
        (output/'resultado.json').write_text(json.dumps(evidence,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
        print('PASS: seis flujos, workers reales, cuatro consultas y consistencia eventual. Evidencia: '+str(output))
        print('Pendientes externos: email recibido por cada integrante, Claude Desktop y Telegram reales.')
    finally:
        if client: client.close()

if __name__=='__main__': main()
