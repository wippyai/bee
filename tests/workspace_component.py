"""Injected workspace resource selection and standalone recovery from origin/main."""
from pathlib import Path
import argparse
import io
import json
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time

import yaml

from native_workspace import NativeDesktop
from native_client import hold_owner, live_owners, stop_owner
from tui_smoke import Desktop
from workspace import ROOT, RUNTIME, classic_workspace, client_layout, database_environment, fixture_workspace, workspace_checkpoint


def injected_database():
    with fixture_workspace(unit_tests=False) as project:
        index = project / 'src/deps/_index.yaml'
        document = yaml.safe_load(index.read_text())
        dependency = next(e for e in document['entries'] if e['component'] == 'bee/workspace')
        next(p for p in dependency['parameters'] if p['name'] == 'target_db')['value'] = 'bee.workspace.db:injected'
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        probe = project / 'src/componentprobe'
        probe.mkdir()
        (probe / 'main.lua').write_text('''local store = require("store")
local function main()
    local db = assert(store.database(nil))
    local rows = assert(db:query("SELECT count(*) AS count FROM workspace_schema_migrations"))
    assert(rows[1].count == 12)
    assert(db:release())
end
return {main = main}
''')
        (probe / '_index.yaml').write_text(yaml.safe_dump({'version': '1.0', 'namespace': 'bee.componentprobe', 'entries': [
            {'name': 'policy', 'kind': 'security.policy', 'policy': {'actions': ['db.get', 'registry.get'],
                'resources': ['bee.workspace.db:injected', 'bee.workspace.persist:store'], 'effect': 'allow'}},
            {'name': 'main', 'kind': 'process.lua', 'source': 'file://main.lua', 'method': 'main',
                'imports': {'store': 'bee.workspace.persist:store'}, 'security': {'policies': ['bee.componentprobe:policy']},
                'meta': {'command': {'name': 'workspace-component-probe', 'short': 'Injected workspace database proof'}}},
        ]}, sort_keys=False))
        resources = project / 'src/injected'
        resources.mkdir()
        (resources / '_index.yaml').write_text(yaml.safe_dump({'version': '1.0', 'namespace': 'bee.workspace.db',
            'entries': [{'name': 'injected', 'kind': 'db.sql.sqlite', 'file': str(project / 'injected.db')}]}, sort_keys=False))
        result = subprocess.run([str(RUNTIME), 'run', '--host', 'bee:terminal', '--set', f'registry.history_path={project / "registry.db"}',
            'workspace-component-probe'], cwd=project, env=database_environment(project), capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        with sqlite3.connect(project / 'injected.db') as db:
            assert db.execute('SELECT count(*) FROM workspace_schema_migrations').fetchone()[0] == 12
            assert db.execute('SELECT count(*) FROM workspaces').fetchone()[0] == 0
        default = project / 'workspace.db'
        if default.exists():
            with sqlite3.connect(default) as db:
                assert db.execute("SELECT count(*) FROM sqlite_master WHERE name='workspace_schema_migrations'").fetchone()[0] == 0
    print('Injected resource: only selected database is migrated; daemon has no folder row', flush=True)


def snapshot(state):
    database = state / 'workspace.db'
    identity = classic_workspace(database)
    with sqlite3.connect(database) as db:
        ledger = db.execute('SELECT id, name, checksum, applied_at FROM workspace_schema_migrations ORDER BY id').fetchall()
        assignments = db.execute('SELECT * FROM workspace_display_assignments ORDER BY workspace_id, view_id, instance_id').fetchall()
        receipts = db.execute('SELECT * FROM workspace_display_transfer_receipts ORDER BY workspace_id, request_id').fetchall()
        bindings = db.execute('SELECT * FROM workspace_application_thread_bindings ORDER BY workspace_id, instance_id').fetchall()
        workspaces = db.execute('SELECT workspace_id, label, root_ref, subpath, state, created_at FROM workspaces ORDER BY workspace_id').fetchall()
        usage = dict(db.execute('SELECT workspace_id, last_used_at FROM workspaces'))
    return {'workspace': identity, 'ledger': ledger, 'checkpoint': workspace_checkpoint(database),
        'layout': client_layout(state / 'workspace.db.client', identity), 'assignments': assignments,
        'receipts': receipts, 'bindings': bindings, 'workspaces': workspaces, 'usage': usage}


def owner_records(project, state, mode):
    probe = project / 'src/componentproof'
    probe.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'tests/fixtures/workspace_component/records.lua', probe / 'records.lua')
    index = (ROOT / 'tests/fixtures/workspace_component/_index.yaml').read_text()
    if not (project / 'modules/workspace').exists():
        index = index.replace('bee.workspace.persist:', 'bee.storage:')
    (probe / '_index.yaml').write_text(index)
    result = subprocess.run([str(RUNTIME), 'run', '--verbose', '--host', 'bee:workers', '--set', f'registry.history_path={state / "probe-registry.db"}',
        'workspace-component-records', mode], cwd=project, env=database_environment(state), capture_output=True, text=True, timeout=60)
    assert result.returncode == 0 and 'RESTORE OWNER RECORDS OPENABLE' in result.stdout + result.stderr, result.stdout + result.stderr
    print(f'Owner records {mode}: catalog, assignments, committed receipt and active binding open through {project.name}', flush=True)


def stopped(ui):
    try:
        ui.wait('Settings', timeout=60)
        ui.wait('Theme', timeout=30)
        ui.quit()
    finally:
        ui.close()


def native_boot(binary, folder, state, application=None):
    started = time.monotonic()
    try:
        stopped(NativeDesktop(binary, folder, state, application=application))
    finally:
        try:
            result = subprocess.run([str(binary), '--state', str(state), 'stop'], cwd=folder,
                capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stdout + result.stderr
        finally:
            for pid in live_owners(binary, state):
                stop_owner(hold_owner(pid, binary, state))
    print(f'Native {state.name}: Settings open and owner stopped in {time.monotonic() - started:.3f}s', flush=True)


def restored_state(before, after):
    assert before['workspace'] == after['workspace']
    for key in ['ledger', 'workspaces', 'assignments', 'receipts', 'bindings']:
        assert before[key] == after[key], key
    for workspace, last_used in before['usage'].items():
        assert after['usage'][workspace] >= last_used
    previous, restored = before['checkpoint']['applications'], after['checkpoint']['applications']
    assert previous and len(previous) == len(restored)
    for left, right in zip(previous, restored):
        for key in ['id', 'instance_id', 'definition_id', 'resume_schema', 'resume_state', 'restart_policy']:
            assert left[key] == right[key], (key, left, right)
    assert before['layout'][0] == after['layout'][0]
    previous_layout, restored_layout = before['layout'][1], after['layout'][1]
    assert restored_layout['scene']['revision'] >= previous_layout['scene']['revision']
    previous_scene = {key: value for key, value in previous_layout['scene'].items() if key != 'revision'}
    restored_scene = {key: value for key, value in restored_layout['scene'].items() if key != 'revision'}
    assert previous_scene == restored_scene, (previous_scene, restored_scene)
    previous_values = {key: value for key, value in previous_layout.items() if key != 'scene'}
    restored_values = {key: value for key, value in restored_layout.items() if key != 'scene'}
    assert previous_values == restored_values, (previous_values, restored_values)


def recovery(binary, evidence):
    evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bee-workspace-component-', dir=ROOT / '.wippy') as temporary:
        folder = Path(temporary)
        origin = folder / 'origin'
        origin.mkdir()
        commit = subprocess.check_output(['git', 'rev-parse', 'origin/main'], cwd=ROOT, text=True).strip()
        archive = subprocess.check_output(['git', 'archive', commit], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(origin, filter='data')
        shutil.copytree(ROOT / '.wippy/vendor', origin / '.wippy/vendor')
        old_state = folder / 'old-state'
        old_state.mkdir()
        stopped(Desktop(old_state, project=origin, runtime=RUNTIME, apps=('bee.settings.app:app',)))
        owner_records(origin, old_state, 'seed')
        before = snapshot(old_state)
        assert len(before['workspaces']) >= 2
        for key in ['assignments', 'receipts', 'bindings']:
            assert before[key], f'empty baseline {key}'
        native_boot(binary, folder, old_state)
        after = snapshot(old_state)
        restored_state(before, after)
        with fixture_workspace(unit_tests=False) as upgraded:
            owner_records(upgraded, old_state, 'verify')
            native_boot(binary, folder, old_state)
            restarted = snapshot(old_state)
            restored_state(before, restarted)
            owner_records(upgraded, old_state, 'verify')
        fresh_state = folder / 'fresh-state'
        native_boot(binary, folder, fresh_state, application='bee.settings.app:app')
        fresh_before = snapshot(fresh_state)
        native_boot(binary, folder, fresh_state)
        fresh_after = snapshot(fresh_state)
        assert fresh_before['workspace'] == fresh_after['workspace']
        assert fresh_before['ledger'] == fresh_after['ledger']
        result = {'baseline': commit, 'workspace': after['workspace'], 'migration_count': len(after['ledger']),
            'old_state_restore': True, 'old_state_second_restart': True, 'fresh_state_restart': True,
            'checkpoint_layout_ids_preserved': True, 'owner_records_openable': True,
            'checkpoint_count': len(after['checkpoint']['applications']),
            'row_counts': {key: len(after[key]) for key in ['workspaces', 'assignments', 'receipts', 'bindings']}}
        (evidence / 'workspace-component.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Standalone: fresh-state restart and origin/main checkpoint/layout/ledger/identity restore pass', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--evidence', type=Path, default=ROOT / '.wippy/proofs')
    args = parser.parse_args()
    injected_database()
    if args.binary:
        recovery(args.binary.resolve(), args.evidence.resolve())
