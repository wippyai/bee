"""Select current application entries from the reusable Lua cache for embedding."""
import hashlib
import json
import os
import shutil
import yaml


LUA_KINDS = ('library.lua', 'function.lua', 'process.lua', 'workflow.lua')


def source_metadata(entry, directory=None):
    source = entry.get('source', '')
    if source.startswith('file://'):
        source = (directory / source[7:]).read_bytes().decode()
    method = '' if entry['kind'] == 'library.lua' else entry.get('method', '')
    imports = dict(entry.get('imports') or {})
    imports.update({name: ':' + name for name in entry.get('modules', [])})
    return {'source_hash': hashlib.sha256((source + method).encode()).hexdigest(), 'imports': imports}


def application_sources(root, directories=None):
    sources = {}
    for index in (index for directory in (directories or [root / 'src', *sorted((root / 'modules').glob('*/src'))]) for index in directory.rglob('_index.yaml')):
        document = yaml.safe_load(index.read_text())
        for entry in document.get('entries', []):
            if entry.get('kind') not in LUA_KINDS:
                continue
            sources[document['namespace'] + ':' + entry['name']] = source_metadata(entry, index.parent)
    return sources


def select_entries(entries, sources, application_ids):
    def compatible(meta):
        current = sources.get(meta['entry_id'])
        return current is not None and (meta['source_hash'] == current['source_hash'] and
                                   {dep['alias']: dep['id'] for dep in meta.get('deps', [])} == current['imports'])
    candidates = {key: meta for key, meta in entries.items()
                  if meta['entry_id'] in application_ids and compatible(meta)}
    while True:
        fingerprints = {meta.get(stage) for meta in candidates.values()
                        for stage in ('compile_fingerprint', 'typecheck_fingerprint') if meta.get(stage)}
        valid = {key: meta for key, meta in candidates.items()
                 if all(dep['id'].startswith(':') or
                        (dep.get('compile_fingerprint') or dep.get('typecheck_fingerprint')) in fingerprints
                        for dep in meta.get('deps', []))}
        if len(valid) == len(candidates):
            return valid
        candidates = valid


def export_seed(cache, destination, sources, application_ids):
    source = cache / 'v1/entries'
    entries = {path.name: json.loads((path / 'meta.json').read_text()) for path in source.iterdir()}
    selected = select_entries(entries, sources, application_ids)
    shutil.rmtree(destination, ignore_errors=True)
    target = destination / 'v1/entries'
    target.mkdir(parents=True)
    size = 0
    for key in selected:
        shutil.copytree(source / key, target / key, copy_function=os.link)
        size += sum(path.stat().st_size for path in (target / key).iterdir())
    print(f'Application seed: {len(selected)} current entries, {size} bytes', flush=True)
    if size >= 1 << 30:
        raise ValueError('current application seed exceeds the pinned runtime limit')


def retain_current(cache, selections):
    directory = cache / 'v1/entries'
    entries = {path.name: json.loads((path / 'meta.json').read_text()) for path in directory.iterdir()}
    selected = {}
    for sources, application_ids in selections:
        selected.update(select_entries(entries, sources, application_ids))
    for key in entries.keys() - selected.keys():
        shutil.rmtree(directory / key)
    size = sum(path.stat().st_size for path in directory.rglob('*') if path.is_file())
    print(f'Reusable Lua cache {cache.name}: {len(selected)} current entries, {size} bytes', flush=True)
