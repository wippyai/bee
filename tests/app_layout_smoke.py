"""Open relocated UI at the supported sizes and retain main's saved state."""
import argparse
import json
import sqlite3
import tempfile
from pathlib import Path

from native_client import hold_owner, live_owners, stop_owner
from native_workspace import NativeDesktop
from tui_smoke import Desktop
from workspace import ROOT

APPS = {
    'bee.settings.app:app': 'BEE SETTINGS',
    'bee.console.app:app': 'Terminal',
    'bee.host.processes.app:app': 'Process Manager',
    'bee.gov.overlays.app:app': 'Overlays',
}


def stop(binary, state):
    for pid in live_owners(binary, state):
        stop_owner(hold_owner(pid, binary, state))


def screens(binary=None):
    for definition, title in APPS.items():
        with tempfile.TemporaryDirectory(prefix='app-layout-', dir=ROOT / '.wippy') as temporary:
            folder = Path(temporary)
            state = folder / 'state'
            state.mkdir()
            ui = NativeDesktop(binary, folder, state, definition) if binary else Desktop(state, apps=(definition,))
            try:
                ui.wait(title, timeout=45)
                ui.key(b'\x1b[23~')
                for width, height in [(120, 36), (80, 24)]:
                    ui.resize(width, height)
                    ui.wait(title)
                    assert ui.process.poll() is None, definition
                    assert 'Application failed' not in ui.text(), ui.text()
                    assert 'Start failed' not in ui.text(), ui.text()
                    if definition == 'bee.console.app:app':
                        marker = f'BEE_APP_LAYOUT_{width}_{height}'
                        ui.key(('printf \'' + marker + '\\n\'\r').encode())
                        ui.wait(marker, timeout=15)
                    if definition == 'bee.settings.app:app':
                        ui.key(b'\t\t\t\t')
                        ui.wait('ABOUT', timeout=15)
                        ui.key(b'\t')
                        ui.wait('BEE SETTINGS')
                print(definition + ': 120x36 / 80x24 pass', flush=True)
                ui.quit(confirm=definition == 'bee.console.app:app')
            finally:
                ui.close()
                if binary:
                    stop(binary, state)
    if binary:
        with tempfile.TemporaryDirectory(prefix='app-layout-desktop-', dir=ROOT / '.wippy') as temporary:
            folder = Path(temporary)
            state = folder / 'state'
            ui = NativeDesktop(binary, folder, state)
            try:
                ui.wait('Sessions', timeout=45)
                ui.key(b'\x17')
                ui.wait(' BEE ')
                ui.quit()
            finally:
                ui.close()
                stop(binary, state)
    print('App layout UI: 4 apps × 2 sizes, About; ' + ('standalone Desktop/Sessions pass' if binary else 'source pass'), flush=True)


def saved(state):
    with sqlite3.connect(state / 'workspace.db') as database:
        rows = database.execute('SELECT value FROM workspace_state').fetchall()
        ledger = database.execute('SELECT id FROM workspace_schema_migrations ORDER BY id').fetchall()
    applications = {item['definition_id']: (item['id'], item['instance_id'], item['resume_state'])
                    for row in rows for item in json.loads(row[0])['applications']}
    return applications, [row[0] for row in ledger]


def layout(state):
    with sqlite3.connect(state / 'workspace.db.client') as database:
        row = database.execute('SELECT value FROM client_layouts ORDER BY generation DESC LIMIT 1').fetchone()
    assert row, 'the client did not save its layout'
    return {(target['workspace_id'], target['instance_id'], target['view_id'])
            for target in json.loads(row[0])['targets']}


def upgrade(previous, binary):
    with tempfile.TemporaryDirectory(prefix='app-layout-upgrade-', dir=ROOT / '.wippy') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        old = NativeDesktop(previous, folder, state, 'bee.settings:app')
        try:
            old.wait('BEE SETTINGS', timeout=45)
            old.open_start()
            old.choose('Apps')
            old.choose('Advanced')
            old.choose('Overlays')
            old.wait('Overlays')
            old.quit()
        finally:
            old.close()
            stop(previous, state)
        before, ledger = saved(state)
        before_layout = layout(state)
        with sqlite3.connect(state / 'workspace.db') as database:
            before_migrations = database.execute('SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id').fetchall()
        assert ledger == list(range(1, 12)), ledger
        assert set(before) == {'bee.settings:app', 'bee.gov.overlays:app'}, before.keys()
        new = NativeDesktop(binary, folder, state, 'bee.settings.app:app')
        try:
            new.wait('BEE SETTINGS', timeout=45)
            new.open_start()
            new.choose('Apps')
            new.choose('Advanced')
            new.choose('Overlays')
            new.wait('Overlays')
            new.quit()
        finally:
            new.close()
            stop(binary, state)
        after, ledger = saved(state)
        assert ledger == list(range(1, 13)), ledger
        assert set(after) == {'bee.settings.app:app', 'bee.gov.overlays.app:app'}, after.keys()
        assert layout(state) == before_layout, 'the client lost saved view targets'
        with sqlite3.connect(state / 'workspace.db') as database:
            after_migrations = database.execute('SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id').fetchall()
        assert after_migrations[:11] == before_migrations, 'an applied workspace migration changed'
        for store, table, expected in [('threads', 'bee_thread_schema_migrations', 28), ('sync', 'bee_sync_schema_migrations', 7)]:
            with sqlite3.connect(state / (store + '.db')) as database:
                assert database.execute('SELECT max(id) FROM ' + table).fetchone()[0] == expected, store
        with sqlite3.connect(state / 'threads.db') as database:
            definitions = {row[0] for row in database.execute('SELECT definition_id FROM bee_thread_app_alias')}
            assert 'bee.settings.app:app' in definitions and 'bee.gov.overlays.app:app' in definitions, definitions
            assert 'bee.settings:app' not in definitions and 'bee.gov.overlays:app' not in definitions, definitions
            assert database.execute('SELECT count(*) FROM bee_thread_definition_migrations').fetchone()[0] == 1
        for definition, prior in before.items():
            assert after[definition.replace(':app', '.app:app')] == prior, (definition, after)
        print('Main 463ac2ea standalone state restart: 2 saved apps retain window/instance/checkpoint identities; workspace ledger 11 → 12', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--previous', type=Path)
    args = parser.parse_args()
    if args.previous:
        upgrade(args.previous.resolve(), args.binary.resolve())
    else:
        screens(args.binary.resolve() if args.binary else None)
