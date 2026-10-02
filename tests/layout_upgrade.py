# SPDX-License-Identifier: MIT
"""Restart origin/main's standalone state and its owner-written callable records."""
import argparse
from contextlib import contextmanager
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path

import yaml

from app_layout_smoke import layout, saved, stop
from native_workspace import NativeDesktop
from workspace import ROOT, RUNTIME, database_environment

STORES = [('placement', 'bee_placement_schema_migrations', 8),
          ('sync', 'bee_sync_schema_migrations', 8),
          ('gateway', 'bee_gateway_schema_migrations', 16)]


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
    overrides = []
    for index in [*source.joinpath('src').rglob('_index.yaml'), *source.joinpath('modules').glob('*/src/**/_index.yaml')]:
        document = yaml.safe_load(index.read_text())
        for entry in document['entries']:
            if entry['kind'] == 'process.service' or (document['namespace'] == 'bee' and entry['name'] == 'gateway_listener'):
                overrides.extend(['--override', document['namespace'] + ':' + entry['name'] + ':lifecycle.auto_start=false'])
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
    for store, table, _ in STORES:
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
        for store, _, count in STORES:
            assert len(prior_ledgers[store]) == count - 1, (store, prior_ledgers[store])
        desktop(binary, folder, state)
        after, upgraded_ledger = saved(state)
        assert before == after, 'Saved application/window/checkpoint identities changed'
        assert workspace_ledger == upgraded_ledger, 'The unchanged workspace store acquired a layout migration'
        assert layout(state) == before_layout, 'Saved client targets changed'
        owner_records(folder / 'new-owners', state, 'layout-verify', ROOT, lint=True)
        upgraded_ledgers = ledgers(state)
        for store, _, count in STORES:
            assert len(upgraded_ledgers[store]) == count, (store, upgraded_ledgers[store])
            assert upgraded_ledgers[store][:-1] == prior_ledgers[store], 'Applied migration changed: ' + store
        desktop(binary, folder, state)
        owner_records(folder / 'restarted-owners', state, 'layout-verify', ROOT)
        assert ledgers(state) == upgraded_ledgers, 'Restart reapplied a migration'
        print('origin/main standalone restart: saved desktop retained; owner-written Placement 7→8, Sync 7→8, Gateway 15→16; cleanup replay and second restart pass', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--previous-source', type=Path, required=True)
    arguments = parser.parse_args()
    upgrade(arguments.previous.resolve(), arguments.binary.resolve(), arguments.previous_source.resolve())
