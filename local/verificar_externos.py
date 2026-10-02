"""Read-only checks of deployed API health, OpenAPI and business metrics."""
import argparse
import json
import urllib.request
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('donaciones', 'donadores', 'logistica', 'incentivos'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--worker', action='append', default=[])
    args = parser.parse_args()
    meters = dict(donaciones='donatrack_donaciones_registradas_total',
        donadores='donadores_necesidades_registradas_total',
        logistica='logistica_paquetes_pendientes',
        incentivos='donatrack_incentivos_donadores_procesados_total',
        worker='logistica_worker_callbacks_exitosos_total')
    services = [(name, getattr(args, name)) for name in ('donaciones', 'donadores', 'logistica', 'incentivos')]
    services += [('worker', url) for url in args.worker]
    failed = []
    for component, base in services:
        address = urlsplit(base)
        if address.scheme not in ('http', 'https') or not address.hostname or address.username or address.password:
            parser.error('Las URLs deben ser HTTP(S), sin usuario ni contraseña.')
        paths = ['/actuator/health', '/actuator/prometheus']
        if component != 'worker':
            paths.append('/v3/api-docs')
        for path in paths:
            try:
                request = urllib.request.Request(base.rstrip('/') + path,
                    headers={'X-Trace-Id': 'validacion-externa-entrega5'})
                with urllib.request.urlopen(request, timeout=60) as response:
                    content = response.read().decode('utf-8')
                if path.endswith('health'):
                    assert json.loads(content)['status'] == 'UP', 'salud distinta de UP'
                elif path.endswith('prometheus'):
                    assert meters[component] in content, 'falta métrica de negocio esperada'
                else:
                    assert json.loads(content).get('paths'), 'OpenAPI sin rutas'
                print(f'PASS {component} {base.rstrip("/")}{path}')
            except Exception as error:
                failed.append(f'{component} {path}: {error}')
    if failed:
        for error in failed:
            print('FAIL', error)
        raise SystemExit(1)
    print('PASS endpoints de lectura. Verificar aparte Claude, Telegram, RabbitMQ, logs y notificaciones reales.')


if __name__ == '__main__':
    main()
