"""Prepare the application, fixtures and Lua seed through one Make entrypoint."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import yaml
import lua_seed

ROOT = Path(__file__).resolve().parents[1]


def check_profile(name, command, cores=None):
    stats = ROOT / '.wippy' / ('prepare-' + name + '.json')
    stats.unlink(missing_ok=True)
    started = time.monotonic()
    environment = dict(os.environ, GOMAXPROCS=str(cores or (2 if name in ('fixtures', 'nonstrict') else min(4, os.cpu_count() or 1))),
                       GOGC='400', GOMEMLIMIT='3GiB', WIPPY_LUA_LINT_CACHE_STATS_FILE=str(stats))
    with subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
        for line in process.stdout:
            print(f'[{name}] {line}', end='', flush=True)
        if process.wait():
            raise subprocess.CalledProcessError(process.returncode, command)
    print(f'Prepare {name}: {time.monotonic() - started:.2f}s; Lua cache ' +
          (json.dumps(json.loads(stats.read_text()), sort_keys=True) if stats.exists() else 'not reported'), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', action='store_true')
    parser.add_argument('--revision')
    args = parser.parse_args()
    cache = Path(os.environ['LUA_CACHE']).resolve()
    config = ROOT / '.wippy.yaml'
    original = config.read_bytes()
    value = yaml.safe_load(original)
    settings = value.setdefault('lua', {}).setdefault('cache', {})
    settings.update(dir=str(cache), max_bytes=4294967296)
    try:
        config.write_text(yaml.safe_dump(value, sort_keys=False))
        subprocess.run(['make', '--no-print-directory', 'binary-identity'] +
                       (['REVISION=' + args.revision] if args.revision else []), check=True)
        subprocess.run([str(ROOT / '.wippy/bin/wippy'), 'install'], check=True)
        inventory = json.loads(subprocess.check_output([str(ROOT / '.wippy/bin/wippy'), 'registry', 'list', '--json'], text=True))
        application_ids = {row['id'] for row in inventory}
        entries = cache / 'v1/entries'
        wippy = str(ROOT / '.wippy/bin/wippy')
        command = [wippy, 'lint', '--memory-limit', '1G', '--set', 'lua.cache.dir=' + str(cache), '--set', 'lua.cache.max_bytes=4294967296']
        strict = ('strict', ['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', 'release-pack'])
        nonstrict = ('nonstrict', command + ['--set', 'lua.type_system.enabled=true', '--set', 'lua.type_system.strict=false'])
        commands = [(*strict, 1), (*nonstrict, 1)]
        if args.fixtures:
            commands.append(('fixtures', ['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', 'fixture-lint'], 2))
        with ThreadPoolExecutor(max_workers=len(commands)) as executor:
            futures = [executor.submit(check_profile, *selected) for selected in commands]
            for future in futures:
                future.result()
        check_profile('default', command)
        subprocess.run(['python3', 'build/release_builder.py'], check=True)
        source = ROOT / '.wippy/release-module'
        shutil.rmtree(source, ignore_errors=True)
        seed = ROOT / '.wippy/application-seed'
        lua_seed.export_seed(cache, seed, ROOT, application_ids)
        selections = [(lua_seed.application_sources(ROOT), application_ids)]
        if args.fixtures:
            fixture_inventory = json.loads(subprocess.check_output([str(ROOT / '.wippy/bin/wippy'), 'registry', 'list', '--json'], cwd=ROOT / 'tests', text=True))
            fixture_sources = lua_seed.application_sources(ROOT, [ROOT / 'tests/.wippy/composition/src', ROOT / 'tests/lua'])
            selections.append((fixture_sources, {row['id'] for row in fixture_inventory}))
        lua_seed.retain_current(cache, selections)
        environment = dict(os.environ, BEE_RELEASE_LUA_CACHE=str(seed), BEE_RELEASE_EXPORT=str(source))
        subprocess.run([str(ROOT / '.wippy/bin/bee-release-builder'), 'build', 'wippy.build.json',
                        '-o', 'dist/bee'], env=environment, check=True)
    finally:
        config.write_bytes(original)


if __name__ == '__main__':
    main()
