"""Generate a Claude Desktop MCP entry with verified absolute Java/JAR paths."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', default=shutil.which('java'))
    parser.add_argument('--salida', type=Path, default=root / 'target/claude-desktop.config.json')
    for component, port in [('donaciones', 8081), ('donadores', 8082), ('logistica', 8083), ('incentivos', 8084)]:
        parser.add_argument('--' + component, default=f'http://localhost:{port}')
    args = parser.parse_args()
    if not args.java or not Path(args.java).is_file():
        parser.error('Indicar --java con la ruta de java.exe (Java 21 o posterior).')
    java = Path(args.java).resolve()
    version = subprocess.run([str(java), '-version'], capture_output=True, text=True, check=True)
    major = re.search(r'version "(\d+)', version.stderr + version.stdout)
    if not major or int(major.group(1)) < 21:
        parser.error('El MCP requiere Java 21 o posterior.')
    jar = root / 'target/donatrack-mcp.jar'
    if not jar.is_file():
        parser.error('Compilar primero el MCP con mvn package.')
    config = {'mcpServers': {'donatrack': {
        'command': str(java), 'args': ['-jar', str(jar.resolve())],
        'env': {name.upper() + '_API_URL': getattr(args, name)
                for name in ('donaciones', 'donadores', 'logistica', 'incentivos')}
    }}}
    args.salida.parent.mkdir(parents=True, exist_ok=True)
    args.salida.write_text(json.dumps(config, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'Configuración generada: {args.salida.resolve()}')
    print('Agregar la entrada donatrack al mcpServers de Claude Desktop y reiniciar Claude.')


if __name__ == '__main__':
    main()
