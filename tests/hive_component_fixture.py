"""Compose actual host value libraries for an isolated Hive consumer fixture."""
from collections import defaultdict
from pathlib import Path
import shutil
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]


def compose(folder, source=None):
    source = source or folder / 'src'
    production = {}
    for index in [*ROOT.joinpath('src').rglob('_index.yaml'), *ROOT.joinpath('modules').glob('*/src/**/_index.yaml')]:
        document = yaml.safe_load(index.read_text())
        for entry in document.get('entries', []):
            production[document['namespace'] + ':' + entry['name']] = (index, entry)
    present = set()
    selected = False
    imports = []
    for index in [*source.rglob('_index.yaml'), *folder.joinpath('modules').glob('*/src/**/_index.yaml')]:
        document = yaml.safe_load(index.read_text())
        for entry in document.get('entries', []):
            present.add(document['namespace'] + ':' + entry['name'])
            if entry.get('component') == 'bee/hive' and entry.get('parameters'):
                selected = True
            imports.extend(entry.get('imports', {}).values())
    dependency = next(entry for entry in yaml.safe_load((ROOT / 'src/deps/_index.yaml').read_text())['entries'] if entry['name'] == 'hive')
    parameters = [parameter for parameter in dependency['parameters'] if isinstance(parameter['value'], str)]
    imports.extend(parameter['value'] for parameter in parameters)
    staged = defaultdict(list)
    while imports:
        identity = imports.pop()
        if identity in present or not identity.startswith('bee.'):
            continue
        index, entry = production[identity]
        if entry['kind'] != 'library.lua':
            raise ValueError('Hive host import is not a value library: ' + identity)
        namespace = yaml.safe_load(index.read_text())['namespace']
        directory = source / 'hive-contracts' / namespace.replace('.', '/')
        directory.mkdir(parents=True, exist_ok=True)
        shutil.copy2(index.parent / entry['source'].removeprefix('file://'), directory / entry['source'].removeprefix('file://'))
        staged[directory].append(entry)
        present.add(identity)
        imports.extend(entry.get('imports', {}).values())
    for directory, entries in staged.items():
        namespace = 'bee.' + '.'.join(directory.relative_to(source / 'hive-contracts/bee').parts)
        (directory / '_index.yaml').write_text(yaml.safe_dump({'version': '1.0', 'namespace': namespace, 'entries': entries}, sort_keys=False))
    if selected:
        return
    directory = source / 'hive-selection'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / '_index.yaml').write_text(yaml.safe_dump({'version': '1.0', 'namespace': 'bee.hive.fixture', 'entries': [
        {'name': 'dependency_hive', 'kind': 'ns.dependency', 'component': 'bee/hive', 'version': '0.1.0-dev', 'parameters': parameters}]}, sort_keys=False))


if __name__ == '__main__':
    compose(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) > 2 else None)
