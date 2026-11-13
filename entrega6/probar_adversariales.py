"""Adversarial HTTP checks for F05/F06/F07 on a disposable local Docker stack.

Uses PostgreSQL and the real APIs. The active phase requires two live workers;
the controlled phase stops only those workers to inject stale snapshots explicitly.
Every assertion is written as PASS/FAIL/ERROR and failures produce a nonzero exit.
No production URLs, database resets, simulated persistence or external notifications.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


PREFIX={'donaciones':'donaciones','donadores':'donadores-entidades','logistica':'logistica'}
EXPECTED_CASES={'active':3,'controlled':13,'verify-restart':1}


def require(condition, **details):
    if not condition:
        raise AssertionError(json.dumps(details,ensure_ascii=False))


class DockerStack:
    def __init__(self, project):
        require(bool(re.fullmatch(r'dds-paquete2-[a-z0-9-]+',project)),project=project)
        self.project=project

    def command(self, *args):
        result=subprocess.run(['docker',*args],capture_output=True,text=True,timeout=90)
        require(result.returncode==0,command=['docker',*args],error=result.stderr[-2000:])
        return result.stdout.strip()

    def container(self, service):
        name=f'{self.project}-{service}-1'
        label=self.command('inspect','--format','{{index .Config.Labels "com.docker.compose.project"}}',name)
        require(label==self.project,container=name,actual_project=label)
        actual=self.command('inspect','--format','{{index .Config.Labels "com.docker.compose.service"}}',name)
        require(actual==service,container=name,actual_service=actual)
        return name

    def running(self, service):
        return self.command('inspect','--format','{{.State.Running}}',self.container(service))=='true'

    def stop(self, service):
        self.command('stop',self.container(service))

    def start(self, service):
        self.command('start',self.container(service))

    def restart(self, service):
        self.command('restart',self.container(service))

    def assert_real_stack(self):
        version=self.command('exec',self.container('postgres'),'psql','-U','demo','-d','logistica','-At','-c','select version()')
        require('PostgreSQL' in version,version=version)
        require(self.running('worker-1') and self.running('worker-2'),workers='both must be running')
        return {'postgres':version,'workers':['worker-1','worker-2'],'project':self.project}

    def worker_consumers(self):
        rows=self.command('exec',self.container('rabbitmq'),'rabbitmqctl','list_queues','-q','name','consumers')
        for row in rows.splitlines():
            values=row.split()
            if values and values[0]=='logistica.matchmaking':
                return int(values[1])
        return 0

    def stock_task_status(self, need):
        require(bool(re.fullmatch(r'[A-Za-z0-9_-]+',need)),need=need)
        query="select completada from reservas_stock_pendientes where necesidad_id='"+need+"'"
        return self.command('exec',self.container('postgres'),'psql','-U','demo','-d','donadores','-At','-c',query)

    def matchmaking_queues(self):
        rows=self.command('exec',self.container('rabbitmq'),'rabbitmqctl','list_queues','-q',
                          'name','messages_ready','messages_unacknowledged')
        result={}
        for row in rows.splitlines():
            values=row.split()
            if values and values[0] in ('logistica.matchmaking','logistica.matchmaking.dlq'):
                result[values[0]]={'ready':int(values[1]),'unacked':int(values[2])}
        return result

    def processed_packages(self, packages):
        result={}
        for worker in ('worker-1','worker-2'):
            lines=self.command('logs',self.container(worker)).splitlines()
            result[worker]=[line for line in lines if 'matchmaking.finalizado' in line
                            and any(re.search(r'paquete='+re.escape(package)+r'(?=\s|[,}\"]|$)',line) for package in packages)]
        return result

    @contextmanager
    def paused_workers(self):
        require(self.running('worker-1') and self.running('worker-2'),workers='controlled phase starts with two running workers')
        try:
            for service in ('worker-1','worker-2'):
                self.stop(service)
            require(not self.running('worker-1') and not self.running('worker-2'),workers='must be stopped before callbacks')
            yield
        finally:
            for service in ('worker-1','worker-2'):
                self.start(service)


class Probe:
    def __init__(self, gateway, stack, output, phase, timeout):
        self.gateway=gateway.rstrip('/')
        self.stack=stack
        self.output=output
        self.phase=phase
        self.timeout=timeout
        self.results=[]
        self.context={}
        self.tag=str(time.time_ns())
        self.sequence=0
        self.output.mkdir(parents=True,exist_ok=True)
        self.donor=None
        self.entity=None

    def http(self, component, method, path, body=None, key=None):
        headers={'Content-Type':'application/json','X-Trace-Id':'paquete2-'+self.phase}
        if key: headers['Idempotency-Key']=key
        request=Request(self.gateway+'/api/'+PREFIX[component]+path,method=method,
                        data=None if body is None else json.dumps(body).encode(),headers=headers)
        try: response=urlopen(request,timeout=45)
        except HTTPError as error: response=error
        with response:
            raw=response.read().decode('utf-8')
            try: value=json.loads(raw) if raw else None
            except json.JSONDecodeError: value=raw
            return response.status,value

    def okay(self, component, method, path, body=None, key=None):
        status,value=self.http(component,method,path,body,key)
        require(200<=status<300,component=component,method=method,path=path,status=status,response=value)
        return value

    def wait(self, description, action, predicate):
        deadline=time.monotonic()+self.timeout
        last=None
        while time.monotonic()<deadline:
            try:
                last=action()
                if predicate(last): return last
            except (URLError,TimeoutError,ConnectionError) as error:
                last=str(error)
            time.sleep(0.3)
        raise AssertionError(f'{description}: no convergió: {last}')

    def save(self):
        record={'phase':self.phase,'gateway':self.gateway,'project':self.stack.project,
                'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'python_version':sys.version.split()[0],
                'context':self.context,'cases':self.results,
                'passed':sum(item['status']=='PASS' for item in self.results),
                'failed':sum(item['status']=='FAIL' for item in self.results),
                'errors':sum(item['status']=='ERROR' for item in self.results),
                'expected_cases':EXPECTED_CASES[self.phase],
                'complete':len(self.results)==EXPECTED_CASES[self.phase]}
        (self.output/(self.phase+'.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

    def case(self, name, action):
        try:
            details=action()
            result={'name':name,'status':'PASS','details':details}
        except AssertionError as error:
            result={'name':name,'status':'FAIL','error':str(error)}
        except Exception as error:
            result={'name':name,'status':'ERROR','error':f'{type(error).__name__}: {error}'}
        self.results.append(result)
        self.save()
        print(result['status']+' '+name,flush=True)

    def bootstrap(self):
        self.context.update(self.stack.assert_real_stack())
        self.wait_health()
        self.donor=self.okay('donadores','POST','/donadores',dict(nombre='Adversarial',apellido=self.tag,
            edad=25,email='adversarial@example.invalid',nroDocumento=self.tag,domicilio='Local'))['id']
        self.entity=self.okay('donadores','POST','/entidades',dict(razonSocial='Paquete2 '+self.tag,
            domicilio='Local',telefono='123',correo='adversarial@example.invalid'))['id']
        self.context.update(donor=self.donor,entity=self.entity)

    def wait_health(self):
        for component in PREFIX:
            self.wait('salud '+component,lambda c=component:self.http(c,'GET','/actuator/health'),
                      lambda value:value[0]==200 and value[1].get('status')=='UP')

    def product(self, label):
        self.sequence+=1
        label=label+' '+str(self.sequence)
        category=self.okay('donaciones','POST','/categorias',dict(nombre=label+' '+self.tag,descripcion='Local'))['id']
        sub=self.okay('donaciones','POST','/categorias',dict(nombre='Sub '+label+' '+self.tag,descripcion='Local',categoriaPadreID=category))['id']
        return self.okay('donaciones','POST','/productos',dict(nombre=label+' '+self.tag,descripcion='Local',categoriaID=category,subcategoriaID=sub))['id']

    def depot(self):
        depot=self.okay('logistica','POST','/depositos',dict(nombre='Paquete2 '+self.tag,direccion='Local',capacidadMaxima=10000))['id']
        self.okay('logistica','PATCH',f'/depositos/{depot}/algoritmo',dict(algoritmo='SUB_ATENDIDOS'))
        return depot

    def need(self, product, quantity, kind='EXTRAORDINARIA'):
        need=self.okay('donadores','POST','/necesidades',dict(entidadID=self.entity,productoSolicitadoID=product,
            descripcion='Paquete2 '+self.tag,cantidadObjetivo=quantity,nivelDeUrgencia=9,tipo=kind))['id']
        # Finish the initial automatic attempt before constructing a controlled
        # interleaving, so an unnoticed third contender cannot change the fixture.
        self.wait('intento inicial durable completado',lambda:self.stack.stock_task_status(need),lambda value:value=='t')
        self.context.setdefault('completed_initial_stock_tasks',[]).append(need)
        return need

    def packages(self, depot, donation=None):
        values=self.okay('logistica','GET',f'/depositos/{depot}')['stockActual']
        return values if donation is None else [value for value in values if value['donacionID']==donation]

    def donate(self, product, quantity, depot):
        donation=self.okay('donaciones','POST','/donaciones',dict(donadorID=self.donor,depositoID=depot,
            productoID=product,cantidad=quantity,descripcion='Paquete2 '+self.tag))['id']
        packages=self.wait('paquete recibido',lambda:self.packages(depot,donation),bool)
        require(sum(package['cantidad'] for package in packages)==quantity,donation=donation,packages=packages)
        return donation,packages[0]['id']

    def assignments(self, need=None):
        values=self.okay('logistica','GET','/asignaciones')
        return values if need is None else [value for value in values if value['necesidadID']==need]

    def stock(self, product):
        return self.okay('logistica','GET',f'/stock/{product}')['cantidadDisponible']

    def callback(self, depot, package, quantity, need=None, assigned=0):
        return self.http('logistica','POST','/internal/matchmaking/resultados',dict(depositoId=depot,
            paqueteId=package,necesidadId=need,cantidadAsignada=assigned,cantidadSobrante=quantity-assigned))

    def stock_request(self, need, product, quantity, key=None):
        return self.http('logistica','POST','/stock/asignaciones',dict(necesidadId=need,productoId=product,cantidad=quantity),key)

    def parallel(self, actions):
        barrier=threading.Barrier(len(actions))
        def perform(action):
            barrier.wait(timeout=15)
            return action()
        with ThreadPoolExecutor(max_workers=len(actions)) as executor:
            return list(executor.map(perform,actions))

    def active_race(self):
        product=self.product('Carrera workers')
        depots=[self.depot(),self.depot()]
        need=self.need(product,10,'RECURRENTE')
        self.wait('dos consumidores reales de matchmaking',self.stack.worker_consumers,lambda value:value==2)
        donations=self.parallel([lambda d=depots[i%2]:self.donate(product,10,d) for i in range(8)])
        self.wait('ocho donaciones procesadas por workers reales',lambda:(self.assignments(need),self.stock(product)),
                  lambda value:sum(a['cantidadAsignada'] for a in value[0])+value[1]==80)
        assignments=self.assignments(need)
        require(sum(a['cantidadAsignada'] for a in assignments)==10,need=need,assignments=assignments)
        require(len(assignments)==1 and self.stock(product)==70,assignments=assignments,stock=self.stock(product))
        require(self.okay('donadores','GET',f'/necesidades/{need}')['cantidadAsignada']==0,
                reason='reservation must not count as delivered')
        worker_logs=self.wait('ambos workers procesaron paquetes de este caso',
            lambda:self.stack.processed_packages([package for _,package in donations]),
            lambda values:all(values[worker] for worker in ('worker-1','worker-2')))
        return {'need':need,'depots':depots,'donations':donations,'assignments':assignments,'stock':70,
                'mode':'two live workers; eight concurrent real donation requests','worker_evidence':worker_logs}

    def need_during_outage(self):
        product=self.product('Alta durable')
        depot=self.depot()
        donation,package=self.donate(product,10,depot)
        self.wait('stock antes de caída',lambda:self.stock(product),lambda value:value==10)
        try:
            self.stack.stop('logistica')
            status,value=self.http('donadores','POST','/necesidades',dict(entidadID=self.entity,
                productoSolicitadoID=product,descripcion='Alta sin Logistica',cantidadObjetivo=10,nivelDeUrgencia=9,tipo='RECURRENTE'))
            require(status==201,status=status,response=value)
            need=value['id']
            require(self.okay('donadores','GET',f'/necesidades/{need}')['id']==need,need=need)
            require(self.stack.stock_task_status(need)=='f',need=need,reason='intent must persist pending while Logistica is down')
            require(not self.stack.running('logistica'),reason='Logistica must remain down during donor API restart')
            self.stack.restart('donadores')
            self.stack.restart('gateway')
            self.wait('Donadores reiniciado con Logistica caída',
                lambda:self.http('donadores','GET','/actuator/health'),
                lambda value:value[0]==200 and value[1].get('status')=='UP')
            require(not self.stack.running('logistica'),reason='do not recover logistics before checking the persisted task')
            detail=self.okay('donadores','GET',f'/necesidades/{need}')
            require(detail['id']==need and detail['cantidadAsignada']==0,need=need,detail=detail)
            require(self.stack.stock_task_status(need)=='f',need=need,reason='pending task must survive Donadores restart')
        finally:
            restoration_errors=[]
            for service in ('donadores','logistica'):
                try: self.stack.start(service)
                except Exception as error: restoration_errors.append(f'{service}: {error}')
            # This stack's gateway caches container DNS. Renew the existing
            # gateway after the API returns; no routing/configuration is changed.
            try: self.stack.restart('gateway')
            except Exception as error: restoration_errors.append(f'gateway: {error}')
            self.context['outage_gateway_dns_refresh']='restarted the existing local gateway after both API restarts'
            require(not restoration_errors,restoration_errors=restoration_errors)
        self.wait_health()
        assignments=self.wait('tarea durable reserva tras volver Logistica',lambda:self.assignments(need),
            lambda values:sum(value['cantidadAsignada'] for value in values)==10)
        status,replay=self.stock_request(need,product,10,'stock-necesidad:'+need)
        require(status==200 and {a['id'] for a in replay}=={a['id'] for a in assignments},status=status,replay=replay,assignments=assignments)
        stock_after=self.stock(product)
        assignments_after=self.assignments(need)
        require(stock_after==0 and len(assignments_after)==1,assignments=assignments_after,stock=stock_after)
        self.wait('tarea marcada completada',lambda:self.stack.stock_task_status(need),lambda value:value=='t')
        return {'need':need,'donation':donation,'package':package,'creation_status':201,'assignments':assignments,
                'replay_status':status,'task_completed_before_recovery':False,
                'task_completed_after_donor_restart_while_logistics_down':False,
                'task_completed_after_recovery':True}

    def stale_callbacks(self, kind, quantities):
        product=self.product('Snapshot '+kind)
        need=self.need(product,10,kind)
        depots=[self.depot(),self.depot()]
        donations=[self.donate(product,quantity,depot) for depot,quantity in zip(depots,quantities)]
        replies=self.parallel([lambda d=depot,p=pair[1],q=quantity:self.callback(d,p,q,need,q)
            for depot,pair,quantity in zip(depots,donations,quantities)])
        require(all(200<=status<300 for status,_ in replies),responses=replies)
        assignments=self.assignments(need)
        total=sum(a['cantidadAsignada'] for a in assignments)
        require(total==10,need=need,assignments=assignments,responses=replies)
        require(self.stock(product)==sum(quantities)-10,stock=self.stock(product),quantities=quantities)
        require(self.okay('donadores','GET',f'/necesidades/{need}')['cantidadAsignada']==0,
                reason='callbacks reserve; they do not report delivery')
        physical=sum(p['cantidad'] for d in depots for p in self.packages(d))
        require(physical==sum(quantities),physical=physical,expected=sum(quantities))
        return {'kind':kind,'need':need,'depots':depots,'responses':replies,'assignments':assignments,'physical':physical,'stock':self.stock(product)}

    def stale_after_delivery(self):
        product=self.product('Saldo entregado')
        need=self.need(product,10)
        first,second=self.depot(),self.depot()
        _,p1=self.donate(product,7,first)
        status,_=self.callback(first,p1,7,need,7)
        require(status==200,status=status)
        self.okay('logistica','POST','/entregas',{'id':p1})
        _,p2=self.donate(product,10,second)
        status,value=self.callback(second,p2,10,need,10)
        require(status==200 and value['cantidadAsignada']==3,status=status,response=value)
        require(self.stock(product)==7,stock=self.stock(product))
        require(self.okay('donadores','GET',f'/necesidades/{need}')['cantidadAsignada']==7,
                reason='pending reservation must not advance delivered counter')
        self.okay('logistica','POST','/entregas',{'id':p2})
        require(self.okay('donadores','GET',f'/necesidades/{need}')['cantidadAsignada']==10,need=need)
        return {'need':need,'second_assignment':value,'stock':7,'delivered':10}

    def stale_negative_snapshot(self):
        product=self.product('Snapshot sin necesidad')
        depot=self.depot()
        _,package=self.donate(product,5,depot)
        need=self.need(product,3)
        status,value=self.callback(depot,package,5)
        assignments=self.assignments(need)
        require(status==200 and len(assignments)==1 and assignments[0]['cantidadAsignada']==3,
                status=status,response=value,assignments=assignments)
        require(self.stock(product)==2,stock=self.stock(product))
        return {'need':need,'snapshot':'no need when worker started','response':value,'stock':2}

    def mixed_stock_callback_race(self):
        product=self.product('Carrera stock callback')
        need=self.need(product,20,'RECURRENTE')
        stock_depot,pending_depot=self.depot(),self.depot()
        _,stock_package=self.donate(product,10,stock_depot)
        status,_=self.callback(stock_depot,stock_package,10)
        require(status==204 and self.stock(product)==10,status=status,stock=self.stock(product))
        _,pending_package=self.donate(product,10,pending_depot)
        current=self.okay('donadores','GET',f'/necesidades/{need}')
        current['cantidadObjetivo']=10
        self.okay('donadores','PUT',f'/necesidades/{need}',current)
        replies=self.parallel([
            lambda:self.callback(pending_depot,pending_package,10,need,10),
            lambda:self.stock_request(need,product,10,'mixed-'+need)])
        require(all(200<=status<300 for status,_ in replies),responses=replies)
        assignments=self.assignments(need)
        require(sum(a['cantidadAsignada'] for a in assignments)==10 and self.stock(product)==10,
                responses=replies,assignments=assignments,stock=self.stock(product))
        return {'need':need,'depots':[stock_depot,pending_depot],'responses':replies,'assignments':assignments,'stock':10}

    def invalid_callback_target(self, mismatch):
        product=self.product('Callback referencia inválida')
        need=self.need(self.product('Producto destino distinto'),3) if mismatch else 'NO-EXISTE-'+self.tag
        depot=self.depot()
        _,package=self.donate(product,5,depot)
        status,value=self.callback(depot,package,5,need,3)
        require(status==204 and not self.assignments(need) and self.stock(product)==5,
                status=status,response=value,assignments=self.assignments(need),stock=self.stock(product))
        return {'need':need,'response_status':status,'stock':5,'assignments':[]}

    def invalid_stock(self, mismatch):
        product=self.product('Stock inválido')
        depot=self.depot()
        _,package=self.donate(product,5,depot)
        status,_=self.callback(depot,package,5)
        require(status==204,status=status)
        need=self.need(self.product('Otro producto'),10) if mismatch else 'NO-EXISTE-'+self.tag
        before=self.assignments(need)
        status,value=self.stock_request(need,product,1)
        require(status==(400 if mismatch else 404),status=status,response=value)
        require(self.assignments(need)==before and self.stock(product)==5,assignments=self.assignments(need),stock=self.stock(product))
        return {'need':need,'status':status,'stock':5,'assignments':before}

    def recurrent_partial(self):
        product=self.product('Recurrente parcial')
        need=self.need(product,20,'RECURRENTE')
        depot=self.depot()
        _,package=self.donate(product,15,depot)
        status,_=self.callback(depot,package,15)
        require(status==204,status=status)
        status,value=self.stock_request(need,product,20)
        require(status==204 and not self.assignments(need) and self.stock(product)==15,status=status,response=value,stock=self.stock(product))
        current=self.okay('donadores','GET',f'/necesidades/{need}')
        current['cantidadObjetivo']=10
        self.okay('donadores','PUT',f'/necesidades/{need}',current)
        status,value=self.stock_request(need,product,5)
        require(status==204 and not self.assignments(need) and self.stock(product)==15,status=status,response=value,assignments=self.assignments(need),stock=self.stock(product))
        return {'need':need,'insufficient_stock_status':204,'partial_request_status':status,'stock':15,'assignments':[]}

    def receipt_and_splitting(self):
        product=self.product('Recepción idempotente')
        other_product=self.product('Payload distinto')
        first,second=self.depot(),self.depot()
        donation,package=self.donate(product,10,first)
        body={'donacionID':donation,'productoID':product,'cantidad':10}
        repeats=self.parallel([lambda:self.http('logistica','POST',f'/depositos/{first}/donacion',body) for _ in range(8)])
        require(all(status==202 for status,_ in repeats),responses=repeats)
        require(len(self.packages(first,donation))==1 and sum(p['cantidad'] for p in self.packages(first,donation))==10,
                packages=self.packages(first,donation))
        for depot,changed in [(second,body),(first,{**body,'cantidad':11}),(first,{**body,'productoID':other_product})]:
            status,value=self.http('logistica','POST',f'/depositos/{depot}/donacion',changed)
            require(status==409,status=status,response=value,depot=depot)
            require(not self.packages(second,donation) and len(self.packages(first,donation))==1,
                    first_packages=self.packages(first,donation),second_packages=self.packages(second,donation))
        status,_=self.callback(first,package,10)
        require(status==204,status=status)
        need=self.need(product,3)
        assigned=self.wait('alta reserva stock después de commit',lambda:self.assignments(need),lambda values:len(values)==1)
        require(assigned[0]['cantidadAsignada']==3,assignments=assigned)
        split=self.packages(first,donation)
        require(len(split)==2 and sorted(p['cantidad'] for p in split)==[3,7],packages=split)
        key='stock-necesidad:'+need
        status,replay=self.stock_request(need,product,3,key)
        require(status==200 and {a['id'] for a in replay}=={a['id'] for a in assigned},status=status,replay=replay)
        status,_=self.stock_request(need,product,4,key)
        require(status==409,status=status)
        self.okay('logistica','POST','/entregas',{'id':assigned[0]['paqueteID']})
        status,replay=self.stock_request(need,product,3,key)
        require(status==200 and {a['id'] for a in replay}=={a['id'] for a in assigned},status=status,replay=replay)
        status,_=self.http('logistica','POST',f'/depositos/{first}/donacion',body)
        require(status==202 and self.stock(product)==7 and len(self.packages(first,donation))==2,
                status=status,stock=self.stock(product),packages=self.packages(first,donation))
        checkpoint={'project':self.stack.project,'depot':first,'donation':donation,'product':product,
                    'body':body,'need':need,'key':key,'assignment_ids':[a['id'] for a in assigned],
                    'packages':self.packages(first,donation),'stock':7}
        (self.output/'checkpoint-reinicio.json').write_text(json.dumps(checkpoint,indent=2)+'\n',encoding='utf-8')
        return checkpoint

    def verify_restart(self):
        checkpoint=json.loads((self.output/'checkpoint-reinicio.json').read_text(encoding='utf-8'))
        require(checkpoint['project']==self.stack.project,checkpoint_project=checkpoint['project'])
        self.context.update(self.stack.assert_real_stack())
        self.wait_health()
        depot=checkpoint['depot']; donation=checkpoint['donation']; product=checkpoint['product']
        before=self.packages(depot,donation)
        require(sorted(before,key=lambda p:p['id'])==sorted(checkpoint['packages'],key=lambda p:p['id']),before=before,checkpoint=checkpoint['packages'])
        status,_=self.http('logistica','POST',f'/depositos/{depot}/donacion',checkpoint['body'])
        after=self.packages(depot,donation)
        require(status==202 and sorted(after,key=lambda p:p['id'])==sorted(before,key=lambda p:p['id']),status=status,packages=after)
        status,replay=self.stock_request(checkpoint['need'],product,3,checkpoint['key'])
        require(status==200 and {a['id'] for a in replay}==set(checkpoint['assignment_ids']),status=status,replay=replay)
        require(self.stock(product)==7,stock=self.stock(product))
        return {'checkpoint':checkpoint,'receipt_status':202,'stock_replay_status':status,'packages':before,'replay':replay,'stock':7}

    def workers_and_queues_restored(self):
        self.wait('ambos consumidores restaurados',self.stack.worker_consumers,lambda value:value==2)
        queues=self.wait('redelivery de callbacks drenado',self.stack.matchmaking_queues,
            lambda values:'logistica.matchmaking' in values
                and values['logistica.matchmaking']=={'ready':0,'unacked':0})
        require(queues.get('logistica.matchmaking.dlq')=={'ready':0,'unacked':0},queues=queues)
        require(self.stack.running('worker-1') and self.stack.running('worker-2'),workers='both must remain running')
        return {'queues':queues,'consumers':2,'workers_running':True}

    def run(self):
        if self.phase=='verify-restart':
            self.case('F07_receipt_and_stock_idempotency_survive_restart',self.verify_restart)
        else:
            self.case('preconditions_real_postgres_two_workers',self.bootstrap)
            if self.donor is None or self.entity is None:
                return 1
            if self.phase=='active':
                self.case('F05_two_workers_cross_depot_concurrent_donations',self.active_race)
                self.case('F06_need_commits_while_logistica_down_then_reserves_once',self.need_during_outage)
            else:
                with self.stack.paused_workers():
                    self.context['callback_mode']='workers stopped; explicit stale snapshots; restored in finally'
                    self.case('F05_recurrent_stale_callbacks_cross_depots',lambda:self.stale_callbacks('RECURRENTE',[10,10]))
                    self.case('F05_extraordinary_stale_callbacks_split_to_remaining_balance',lambda:self.stale_callbacks('EXTRAORDINARIA',[7,7]))
                    self.case('F05_delivered_balance_is_not_subtracted_twice',self.stale_after_delivery)
                    self.case('F05_negative_worker_snapshot_rechecks_new_need',self.stale_negative_snapshot)
                    self.case('F05_stock_and_callback_share_the_same_reservation_limit',self.mixed_stock_callback_race)
                    self.case('F06_callback_rechecks_nonexistent_need',lambda:self.invalid_callback_target(False))
                    self.case('F06_callback_rechecks_product_match',lambda:self.invalid_callback_target(True))
                    self.case('F06_stock_rejects_nonexistent_need_without_side_effects',lambda:self.invalid_stock(False))
                    self.case('F06_stock_rejects_wrong_product_without_side_effects',lambda:self.invalid_stock(True))
                    self.case('F06_recurrent_stock_requires_entire_balance',self.recurrent_partial)
                    self.case('F07_receipt_replay_conflicts_and_legitimate_splitting',self.receipt_and_splitting)
                self.case('postconditions_workers_restored_queue_drained_no_dlq',self.workers_and_queues_restored)
        self.save()
        return int(len(self.results)!=EXPECTED_CASES[self.phase] or any(result['status']!='PASS' for result in self.results))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gateway',default='http://127.0.0.1:8080')
    parser.add_argument('--project',required=True)
    parser.add_argument('--phase',choices=['active','controlled','verify-restart'],required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--timeout',type=int,default=120)
    args=parser.parse_args()
    if urlparse(args.gateway).hostname not in ('localhost','127.0.0.1'):
        parser.error('Only loopback HTTP endpoints are allowed.')
    probe=Probe(args.gateway,DockerStack(args.project),args.output,args.phase,args.timeout)
    try:
        code=probe.run()
    except Exception as error:
        probe.results.append({'name':'phase_lifecycle','status':'ERROR','error':f'{type(error).__name__}: {error}'})
        probe.save()
        print('ERROR phase_lifecycle: '+str(error),flush=True)
        code=1
    raise SystemExit(code)


if __name__=='__main__':
    main()
