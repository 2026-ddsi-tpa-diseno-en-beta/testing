"""Generate the analyst's Postman collection from the same catalog as MCP and Telegram."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
PREFIX={'donaciones':'/api/donaciones','donadores':'/api/donadores-entidades','logistica':'/api/logistica','incentivos':'/api/incentivos','consultas':'/api/consultas','gateway':''}
def identifier(operation):
    name=operation['name']
    if 'donador' in name or name in ('asignar_mision','asignar_insignia'): return 'donadorID'
    for word in ('producto','categoria','identificador','entidad','necesidad','deposito','mision','insignia','asignacion','donacion'):
        if word in name: return word+'ID'
    return 'id'

def sample(name,schema):
    if 'enum' in schema:return schema['enum'][0]
    if schema.get('type')=='integer':return 100 if name=='capacidadMaxima' else 25 if name=='edad' else 5
    if schema.get('type')=='array':return ['{{paqueteID}}']
    if name.lower().endswith('id'):return '{{'+name+'}}'
    return {'fecha':'2026-11-06','email':'demo@example.com','correo':'demo@example.com','telefono':'123','nroDocumento':'123','domicilio':'Medrano','direccion':'Medrano'}.get(name,'Demo')

def main():
    catalog=json.loads((ROOT/'mcp-server/src/main/resources/tools.json').read_text(encoding='utf-8'))
    folders={key:[] for key in ('consultas','donadores','donaciones','logistica','incentivos','gateway')}
    variables={'gateway':'http://127.0.0.1:8080'}
    for op in catalog:
        props=op['schema']['properties']; ref=identifier(op)
        path=op['path'].replace('{id}','{{'+ref+'}}')
        variables.setdefault(ref,'')
        url='{{gateway}}'+PREFIX[op['component']]+path
        request={'method':op['method'],'header':[{'key':'Accept','value':'application/json'}],
                 'url':url,'description':op['description']+'\nUsar los IDs del escenario; las consultas reflejan consistencia eventual.'}
        if 'datos' in props:
            data={name:sample(name,schema) for name,schema in props['datos']['properties'].items() if name in props['datos']['required']}
            request['body']={'mode':'raw','raw':json.dumps(data,ensure_ascii=False,indent=2),'options':{'raw':{'language':'json'}}}
            request['header'].append({'key':'Content-Type','value':'application/json'})
            for key,value in data.items():
                if isinstance(value,str) and value.startswith('{{'):variables.setdefault(value[2:-2],'')
        if 'filtros' in props:
            required=props['filtros'].get('required',[])
            values=[key+'={{'+key+'}}' for key in props['filtros']['properties'] if key in required]
            for key in props['filtros']['properties']:variables.setdefault(key,'2026-11-06' if key=='fecha' else '')
            if values:request['url']+='?'+('&'.join(values))
            request['description']+='\nFiltros admitidos: '+', '.join(props['filtros']['properties'])
        script=['pm.test("Respuesta exitosa", () => pm.expect(pm.response.code).to.be.within(200,299));']
        if op['name'].startswith('crear_') or op['name']=='realizar_donacion':
            script.append('if(pm.response.code < 300) { const data=pm.response.json(); if(data.id) pm.collectionVariables.set('+json.dumps(ref)+',data.id); }')
        folders[op['component']].append({'name':op['name'].replace('_',' ').capitalize(),'request':request,'event':[{'listen':'test','script':{'type':'text/javascript','exec':script}}]})
    collection={'info':{'name':'DonaTrack · Entrega 6 · Validación funcional','schema':'https://schema.getpostman.com/json/collection/v2.1.0/collection.json','description':'Catálogo compartido con MCP y Telegram. Preparar el escenario con probar_demo.py y completar variables antes de ejecutar escrituras. No ejecutar todos los ABM indiscriminadamente.'},
      'variable':[{'key':k,'value':v} for k,v in variables.items()],
      'item':[{'name':name.capitalize(),'item':items} for name,items in folders.items()]}
    output=Path(__file__).parent/'DonaTrack_Entrega6.postman_collection.json'
    output.write_text(json.dumps(collection,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'{len(catalog)} operaciones exportadas a Postman')

if __name__=='__main__':main()
