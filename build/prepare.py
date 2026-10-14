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

ROOT = Path(__file__).resolve().parents[1]


def check_profile(name, command):
    stats = ROOT / '.wippy' / ('prepare-' + name + '.json')
    stats.unlink(missing_ok=True)
    started = time.monotonic()
    environment = dict(os.environ, GOMAXPROCS='2' if name == 'fixtures' else '1',
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
    value.setdefault('lua', {}).setdefault('cache', {})['dir'] = str(cache)
    try:
        config.write_text(yaml.safe_dump(value, sort_keys=False))
        subprocess.run(['make', '--no-print-directory', 'binary-identity'] +
                       (['REVISION=' + args.revision] if args.revision else []), check=True)
        subprocess.run([str(ROOT / '.wippy/bin/wippy'), 'install'], check=True)
        commands = [('strict', ['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', 'release-pack'])]
        wippy = str(ROOT / '.wippy/bin/wippy')
        command = [wippy, 'lint', '--memory-limit', '1G', '--set', 'lua.cache.dir=' + str(cache)]
        commands.append(('nonstrict', command + ['--set', 'lua.type_system.enabled=true', '--set', 'lua.type_system.strict=false']))
        if args.fixtures:
            commands.append(('fixtures', ['make', '--no-print-directory', '-o', 'tools', '-o', 'binary-identity', 'fixture-lint']))
        with ThreadPoolExecutor(max_workers=len(commands)) as executor:
            futures = [executor.submit(check_profile, name, selected) for name, selected in commands]
            for future in futures:
                future.result()
        check_profile('default', command)
        subprocess.run(['python3', 'build/release_builder.py'], check=True)
        source = ROOT / '.wippy/release-module'
        shutil.rmtree(source, ignore_errors=True)
        environment = dict(os.environ, BEE_RELEASE_LUA_CACHE=str(cache), BEE_RELEASE_EXPORT=str(source))
        subprocess.run([str(ROOT / '.wippy/bin/bee-release-builder'), 'build', 'wippy.build.json',
                        '-o', 'dist/bee'], env=environment, check=True)
    finally:
        config.write_bytes(original)


if __name__ == '__main__':
    main()
