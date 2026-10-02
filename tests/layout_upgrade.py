# SPDX-License-Identifier: MIT
"""Restart origin/main's standalone state and its owner-written callable records."""
import argparse
from contextlib import contextmanager
import json
import re
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path

import yaml

from app_layout_smoke import layout, saved, stop
from native_workspace import NativeDesktop
from workspace import ROOT, RUNTIME, database_environment

STORES = [('placement', 'bee_placement_schema_migrations', 8, 9),
          ('sync', 'bee_sync_schema_migrations', 8, 9),
          ('gateway', 'bee_gateway_schema_migrations', 16, 17),
          ('resources', 'bee_resource_schema_migrations', 3, 4),
          ('credentials', 'bee_credential_schema_migrations', 6, 7)]


@contextmanager
def upgrade_fixture():
    folder = Path(tempfile.mkdtemp(prefix='layout-upgrade-', dir=ROOT / '.wippy'))
    try:
        yield folder
    except BaseException:
        print('Layout upgrade fixture preserved: ' + str(folder), flush=True)
        raise
    else:
        shutil.rmtree(folder)


def stage(folder, source):
    folder.mkdir()
    for name in ['.wippy.yaml', 'wippy.yaml', 'wippy.lock']:
        shutil.copy2(source / name, folder / name)
    shutil.copytree(source / 'src', folder / 'src')
    (folder / 'modules').symlink_to(source / 'modules', target_is_directory=True)
    (folder / '.wippy').mkdir()
    (folder / '.wippy/vendor').symlink_to(ROOT / '.wippy/vendor', target_is_directory=True)
    shutil.copytree(ROOT / 'tests/fixtures/layout_upgrade', folder / 'src/tests/layout')
    if source != ROOT:
        moves = json.loads((ROOT / 'build/layout_root_moves.json').read_text())
        source_ids = set()
        for index in [*source.joinpath('src').rglob('_index.yaml'),
                      *source.joinpath('modules').glob('*/src/**/_index.yaml')]:
            document = yaml.safe_load(index.read_text())
            source_ids.update(document['namespace'] + ':' + entry['name'] for entry in document['entries'])
        previous_ids = {current: previous for previous, current in moves.items()
                        if previous in source_ids and current not in source_ids}
        for path in (folder / 'src/tests/layout').rglob('*'):
            if path.suffix in {'.lua', '.yaml'}:
                text = re.sub(r'bee(?:\.[A-Za-z0-9_.-]+)*:[A-Za-z0-9_.-]+',
                              lambda match: previous_ids.get(match[0], match[0]), path.read_text())
                path.write_text(text)
    overrides = []
    for index in [*source.joinpath('src').rglob('_index.yaml'), *source.joinpath('modules').glob('*/src/**/_index.yaml')]:
        document = yaml.safe_load(index.read_text())
        for entry in document['entries']:
            if entry['kind'] == 'process.service' or entry['kind'] == 'http.service':
                overrides.extend(['--override', document['namespace'] + ':' + entry['name'] + ':lifecycle.auto_start=false'])
                overrides.extend(['--override', document['namespace'] + ':' + entry['name'] + ':lifecycle.startup=optional'])
    return overrides


def owner_records(folder, state, command, source, lint=False):
    overrides = stage(folder, source)
    environment = database_environment(state)
    environment.update(HOME=str(folder), XDG_CONFIG_HOME=str(folder / '.config'),
                       BEE_PLACEMENT_ROOT=str(state / 'attempts'), TMPDIR=str(folder), TERM='xterm-256color')
    if lint:
        subprocess.run([str(RUNTIME), 'lint', '--ns', 'bee.layout.fixture', '--strict-any',
                        '--set', 'lua.type_system.enabled=true', '--set', 'lua.type_system.strict=true'],
                       cwd=folder, env=environment, check=True, timeout=600)
    result = subprocess.run([str(RUNTIME), 'run', *overrides, command], cwd=folder, env=environment,
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        print(result.stdout + result.stderr, flush=True)
        result.check_returncode()
    print(result.stdout, end='', flush=True)


def desktop(binary, folder, state):
    ui = NativeDesktop(binary, folder, state, 'bee.settings.app:app')
    try:
        ui.wait('BEE SETTINGS', timeout=90)
        ui.quit()
    finally:
        ui.close()
        stop(binary, state)


def ledgers(state):
    result = {}
    for store, table, _, _ in STORES:
        with sqlite3.connect('file:' + str(state / (store + '.db')) + '?mode=ro', uri=True) as db:
            result[store] = db.execute('SELECT id, name, checksum FROM ' + table + ' ORDER BY id').fetchall()
    return result


def upgrade(previous, binary, source):
    with upgrade_fixture() as folder:
        state = folder / 'state'
        state.mkdir()
        desktop(previous, folder, state)
        before, workspace_ledger = saved(state)
        before_layout = layout(state)
        owner_records(folder / 'old-owners', state, 'layout-seed', source, lint=True)
        prior_ledgers = ledgers(state)
        for store, _, prior_count, count in STORES:
            assert len(prior_ledgers[store]) == prior_count, (store, prior_ledgers[store])
        desktop(binary, folder, state)
        after, upgraded_ledger = saved(state)
        assert before == after, 'Saved application/window/checkpoint identities changed'
        assert workspace_ledger == upgraded_ledger, 'The unchanged workspace store acquired a layout migration'
        assert layout(state) == before_layout, 'Saved client targets changed'
        owner_records(folder / 'new-owners', state, 'layout-verify', ROOT, lint=True)
        upgraded_ledgers = ledgers(state)
        for store, _, prior_count, count in STORES:
            assert len(upgraded_ledgers[store]) == count, (store, upgraded_ledgers[store])
            assert upgraded_ledgers[store][:prior_count] == prior_ledgers[store], 'Applied migration changed: ' + store
        desktop(binary, folder, state)
        owner_records(folder / 'restarted-owners', state, 'layout-verify', ROOT)
        assert ledgers(state) == upgraded_ledgers, 'Restart reapplied a migration'
        print('origin/main standalone restart: saved desktop retained; owner-written Placement 8→9, Sync 8→9, Gateway 16→17, Resources 3→4, Credentials 6→7; cleanup replay and second restart pass', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--previous-source', type=Path, required=True)
    arguments = parser.parse_args()
    upgrade(arguments.previous.resolve(), arguments.binary.resolve(), arguments.previous_source.resolve())
