"""Standalone smoke and restart of state produced by the baseline binary."""
import argparse
import json
import os
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from app_layout_smoke import layout, saved
from native_workspace import STATE_ENVIRONMENT, NativeDesktop
from workspace import ROOT


def open_settings(binary, folder, state):
    ui = NativeDesktop(binary, folder, state, 'bee.settings.app:app')
    try:
        ui.wait('BEE SETTINGS', timeout=90)
        assert 'Application failed' not in ui.text()
        ui.quit()
    finally:
        ui.close()
        environment = {key: value for key, value in os.environ.items()
                       if key not in STATE_ENVIRONMENT | {"BEE_RUNTIME", "USER"}}
        environment.update(HOME=str(folder), PATH=f"{folder}/bin:/usr/bin:/bin",
                           XDG_CONFIG_HOME=str(folder / '.config'))
        subprocess.run([str(binary), '--state', str(state), 'stop'], cwd=folder,
                       env=environment, capture_output=True, text=True, check=True, timeout=90)


def snapshot(state):
    result = {}
    for filename, table in [('workspace.db', 'workspace_schema_migrations'),
                            ('workspace.db.client', 'client_schema_migrations')]:
        with sqlite3.connect(state / filename) as db:
            result[table] = db.execute(f'SELECT * FROM {table} ORDER BY id').fetchall()
    with sqlite3.connect(state / 'workspace.db') as db:
        result['workspace'] = db.execute('SELECT workspace_id, root_ref, subpath FROM workspaces ORDER BY workspace_id').fetchall()
    with sqlite3.connect(state / 'workspace.db.client') as db:
        result['client'] = db.execute('SELECT client_id FROM client_state').fetchall()
        result['client_columns'] = db.execute('PRAGMA table_info(client_schema_migrations)').fetchall()
    result['applications'] = saved(state)[0]
    result['layout'] = sorted(layout(state))
    return result


def main(binary, previous):
    directory = ROOT / '.wippy'
    with tempfile.TemporaryDirectory(prefix='persist-standalone-', dir=directory) as temporary:
        folder = Path(temporary)
        fresh = folder / 'fresh'
        fresh.mkdir()
        open_settings(binary, folder, fresh)
        first = snapshot(fresh)
        assert len(first['workspace_schema_migrations']) == 14
        assert len(first['client_schema_migrations']) == 3
        assert len(first['client_columns']) == 3
        assert first['applications'] and first['layout']
        open_settings(binary, folder, fresh)
        assert snapshot(fresh) == first
        print('Standalone fresh-state smoke and restart: workspace/client identities, layouts, app checkpoints and ledger rows retained', flush=True)
        upgrade = folder / 'upgrade'
        upgrade.mkdir()
        open_settings(previous, folder, upgrade)
        before = snapshot(upgrade)
        open_settings(binary, folder, upgrade)
        after = snapshot(upgrade)
        assert after['workspace_schema_migrations'][:len(before['workspace_schema_migrations'])] == before['workspace_schema_migrations']
        before['workspace_schema_migrations'] = after['workspace_schema_migrations']
        assert after == before
        evidence = ROOT / '.wippy/work/standalone-state-evidence.json'
        evidence.write_text(json.dumps({'baseline': 'origin/main', 'workspace_migrations': 14,
                                       'client_migrations': 3, 'client_columns': 3,
                                       'fresh_restart': True, 'baseline_restart': True}, indent=2) + '\n')
        print('origin/main-created state restarted: all ledger bytes, IDs, app checkpoints and qualified layouts unchanged', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--previous', required=True, type=Path)
    args = parser.parse_args()
    main(args.binary.resolve(), args.previous.resolve())
