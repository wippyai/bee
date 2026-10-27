"""Check Lua profiles and assemble their shared release seed."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import time
import yaml

if __package__:
    from . import ci, lua_seed
else:
    import ci
    import lua_seed

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ('strict', 'nonstrict', 'fixtures')


def manifest():
    """The build manifest the Makefile selected: the release one or a local source build's."""
    return os.environ.get('MANIFEST', 'wippy.build.json')


def make(*targets):
    subprocess.run(['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', *targets], check=True)


def check_profile(name, command, cores=None):
    stats = ROOT / '.wippy' / ('prepare-' + name + '.json')
    stats.unlink(missing_ok=True)
    started = time.monotonic()
    environment = dict(os.environ, GOMAXPROCS=str(cores or min(4, os.cpu_count() or 1)),
                       GOGC='400', GOMEMLIMIT='3GiB', WIPPY_LUA_LINT_CACHE_STATS_FILE=str(stats))
    with subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
        for line in process.stdout:
            print(f'[{name}] {line}', end='', flush=True)
        if process.wait():
            raise subprocess.CalledProcessError(process.returncode, command)
    print(f'Prepare {name}: {time.monotonic() - started:.2f}s; Lua cache ' +
          (json.dumps(json.loads(stats.read_text()), sort_keys=True) if stats.exists() else 'not reported'), flush=True)


@contextlib.contextmanager
def cache_config(cache):
    config = ROOT / '.wippy.yaml'
    original = config.read_bytes()
    value = yaml.safe_load(original)
    value.setdefault('lua', {}).setdefault('cache', {}).update(dir=str(cache), max_bytes=4294967296)
    try:
        config.write_text(yaml.safe_dump(value, sort_keys=False))
        yield
    finally:
        config.write_bytes(original)


def selection(root, directories=None):
    wippy = str(ROOT / '.wippy/bin/wippy')
    inventory = json.loads(subprocess.check_output([wippy, 'registry', 'list', '--json'], cwd=root, text=True))
    sources = lua_seed.application_sources(root, directories)
    # Module packs can differ from both repository sources and fixture overlays.
    # Resolve their actual installed sources instead of accepting every cached version.
    missing = [row['id'] for row in inventory if row['kind'] in lua_seed.LUA_KINDS and row['id'] not in sources]

    def load(entry_id):
        entry = json.loads(subprocess.check_output([wippy, 'registry', 'show', entry_id, '--json'], cwd=root, text=True))
        return entry_id, lua_seed.source_metadata(dict(entry['data'], kind=entry['kind']))

    with ThreadPoolExecutor(max_workers=4) as executor:
        sources.update(executor.map(load, missing))
    return sources, {row['id'] for row in inventory}


def selections(fixtures=False):
    selected = [selection(ROOT)]
    if fixtures:
        selected.append(selection(ROOT / 'tests', [ROOT / 'tests/.wippy/composition/src', ROOT / 'tests/lua']))
    return selected


def commands(cache):
    command = [str(ROOT / '.wippy/bin/wippy'), 'lint', '--memory-limit', '1G',
               '--set', 'lua.cache.dir=' + str(cache), '--set', 'lua.cache.max_bytes=4294967296']
    return {'strict': ['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', 'release-pack'],
            'nonstrict': command + ['--set', 'lua.type_system.enabled=true', '--set', 'lua.type_system.strict=false'],
            'fixtures': ['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', 'fixture-lint'],
            'default': command}


def export_profile(profile, cache, fingerprint):
    lua_seed.retain_current(cache, selections(profile == 'fixtures'))
    record = ROOT / '.wippy/profile.json'
    record.write_text(json.dumps({'profile': profile, 'source_fingerprint': fingerprint}))
    with tarfile.open(ROOT / ('.wippy/' + profile + '.tar'), 'w') as archive:
        archive.add(record, arcname='.wippy/profile.json')
        archive.add(cache, arcname='.wippy/lua-cache')
        if profile == 'strict':
            for name in ('dist/bee.wapp', manifest(), 'src/env/identity/_index.yaml'):
                archive.add(ROOT / name, arcname=name)


def assemble(cache, fixtures):
    selected = selections(fixtures)
    source = ROOT / '.wippy/release-module'
    shutil.rmtree(source, ignore_errors=True)
    seed = ROOT / '.wippy/application-seed'
    lua_seed.export_seed(cache, seed, *selected[0])
    lua_seed.retain_current(cache, selected)
    subprocess.run(['python3', 'build/release_builder.py'], check=True)
    environment = dict(os.environ, BEE_RELEASE_LUA_CACHE=str(seed), BEE_RELEASE_EXPORT=str(source))
    subprocess.run([str(ROOT / '.wippy/bin/bee-release-builder'), 'build', manifest(),
                    '-o', 'dist/bee'], env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', action='store_true')
    parser.add_argument('--revision')
    parser.add_argument('--profile', choices=PROFILES)
    parser.add_argument('--assemble', action='store_true')
    args = parser.parse_args()
    cache = Path(os.environ['LUA_CACHE']).resolve()
    fingerprint = ci.application_key()
    (ROOT / '.wippy/cache/application.tar').unlink(missing_ok=True)
    with cache_config(cache):
        subprocess.run(['make', '--no-print-directory', 'binary-identity'] +
                       (['REVISION=' + args.revision] if args.revision else []), check=True)
        subprocess.run([str(ROOT / '.wippy/bin/wippy'), 'install'], check=True)
        checks = commands(cache)
        if args.profile:
            check_profile(args.profile, checks[args.profile])
            export_profile(args.profile, cache, fingerprint)
            return
        if args.assemble:
            if args.fixtures:
                make('fixture-install')
        else:
            profiles = ['strict', 'nonstrict'] + (['fixtures'] if args.fixtures else [])
            with ThreadPoolExecutor(max_workers=len(profiles)) as executor:
                futures = [executor.submit(check_profile, name, checks[name], 2 if name == 'fixtures' else 1) for name in profiles]
                for future in futures:
                    future.result()
        check_profile('default', checks['default'])
        assemble(cache, args.fixtures)


if __name__ == '__main__':
    main()
