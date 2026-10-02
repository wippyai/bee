"""Real SQLite migration opens, concurrent writers and SIGKILL recovery."""
from concurrent.futures import ThreadPoolExecutor
import json
import argparse
import shutil
from pathlib import Path
import hashlib
import os
import re
import select
import signal
import sqlite3
import subprocess
import time

import yaml

from workspace import ROOT, RUNTIME, database_environment, fixture_workspace

OWNERS = {
    'workspace': ('bee.workspace.db:runner', 'workspace_schema_migrations', 14),
    'client': ('bee.client.db:runner', 'client_schema_migrations', 3),
    'sync': ('bee.sync:runner', 'bee_sync_schema_migrations', len(re.findall(r'\bid = \d+, name =', (ROOT / 'modules/sync/src/migrations/migrations.lua').read_text()))),
}
PROBE = '''local workspace = require("workspace")
local client = require("client")
local sync = require("sync")
local ledger = require("ledger")
local io = require("io")
local sql = require("sql")
type History = {migrations: {ledger.Migration}, ledger: ledger.Ledger}
local histories: {[string]: History} = {
    threads = {migrations = require("threads_migrations").all(), ledger = {table = "bee_thread_schema_migrations", label = "thread"}},
    governance = {migrations = require("governance_migrations").all(), ledger = {table = "bee_governance_migrations", label = "governance"}},
    gateway = {migrations = require("gateway_migrations").all(), ledger = {table = "bee_gateway_schema_migrations", label = "gateway"}},
    sync = {migrations = require("sync_migrations").all(), ledger = {table = "bee_sync_schema_migrations", label = "sync"}},
}
local function report()
    for _, phase in ipairs(ledger.progress()) do assert(io.print("PERSIST_PROGRESS " .. phase)) end
    for _, phase in ipairs(ledger.boot_phases()) do assert(io.print("PERSIST_BOOT " .. phase)) end
end
local function main(owner: string)
    local history = histories[owner:match("^history%-(.+)$") or ""]
    if history then
        local db = assert(sql.get("bee.persistprobe:history"))
        assert(ledger.apply(db, history.ledger, history.migrations))
        assert(db:release())
        report()
        return
    end
    local db, err
    if owner == "workspace" then db, err = workspace.database("bee.workspace.db:runner")
    elseif owner == "client" then
        local store, failure = client.open("bee.client.db:runner", string.rep("a", 32))
        if not store then report(); error(tostring(failure)) end
        assert(client.close(store))
    elseif owner == "sync" then db, err = sync.open("bee.sync:runner")
    else error("unknown owner") end
    if owner ~= "client" then
        if not db then report(); error(tostring(err)) end
        assert(db:release())
    end
    report()
end
return {main = main}
'''


def declared_migrations(source):
    from test_migration_histories import migrations
    return migrations(source)


def bytes_check():
    from test_migration_histories import SOURCES
    moved = subprocess.check_output(['git', 'diff', '--name-status', '-M', '893d1216', 'origin/main'], cwd=ROOT, text=True)
    baseline_paths = {parts[2]: parts[1] for line in moved.splitlines()
                      if (parts := line.split('\t'))[0].startswith('R')}
    baseline_paths[SOURCES['workspace']] = 'src/storage/store.lua'
    baseline_paths['modules/client/src/migrations/migrations.lua'] = 'src/client/store.lua'
    paths = set(SOURCES.values()) | {'modules/client/src/migrations/migrations.lua'}
    paths |= {str(path.relative_to(ROOT)) for path in (ROOT / 'modules').glob('*/src/migrations/*.lua')}
    for path in sorted(paths):
        current = declared_migrations((ROOT / path).read_text())
        for baseline in ['893d1216', 'origin/main']:
            baseline_path = baseline_paths.get(path, path) if baseline == '893d1216' else path
            if path == 'modules/client/src/migrations/migrations.lua':
                exists = subprocess.run(['git', 'cat-file', '-e', baseline + ':' + path], cwd=ROOT, capture_output=True)
                if exists.returncode:
                    baseline_path = 'src/client/store.lua'
            prior = subprocess.check_output(['git', 'show', baseline + ':' + baseline_path], cwd=ROOT, text=True)
            shipped = declared_migrations(prior)
            assert current[:len(shipped)] == shipped, (baseline, path)
    print('All owner applied SQL at shipped baseline 893d1216 and origin/main is unchanged; repairs append new migrations', flush=True)


def seed(path, owner, workspace_revision=7, original_nine=True):
    if owner == 'sync':
        source = (ROOT / 'modules/sync/src/migrations/migrations.lua').read_text()
        initial = re.search(r'local INITIAL = \[\[(.*?)\]\]', source, re.S)[1].removeprefix('\n')
        expected = [(1, 'owner_local_feed', initial)]
    else:
        source = ROOT / ('modules/workspace/src/migrations/migrations.lua' if owner == 'workspace' else 'modules/client/src/migrations/migrations.lua')
        expected = declared_migrations(source.read_text())
    limit = workspace_revision if owner == 'workspace' else 1
    if owner == 'workspace' and workspace_revision == 9 and original_nine:
        identity, name, sql = expected[8]
        sql = sql.replace('bee.approvals.inbox.app:app', 'bee.approvals.inbox:app')
        assert hashlib.sha256((name + '\n' + sql).encode()).hexdigest() == '46544288073bfa24da5cc43334239ce9774e0a816624ab82b958db8c9acae71a'
        expected[8] = (identity, name, sql)
    table = OWNERS[owner][1]
    with sqlite3.connect(path) as db:
        if owner == 'workspace' and workspace_revision >= 8:
            db.execute('CREATE TEMP TABLE workspace_migration_run (fresh INTEGER)')
            db.execute('INSERT INTO workspace_migration_run VALUES (0)')
        timestamp = ', applied_at TEXT NOT NULL' if owner != 'client' else ''
        db.execute(f'CREATE TABLE {table} (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL{timestamp})')
        for identity, name, sql in expected[:limit]:
            db.executescript(sql)
            checksum = hashlib.sha256((name + '\n' + sql).encode()).hexdigest()
            row = (identity, name, checksum, 'original') if timestamp else (identity, name, checksum)
            db.execute(f'INSERT INTO {table} VALUES ({",".join("?" for _ in row)})', row)
        if owner == 'workspace':
            identity = db.execute('SELECT workspace_id FROM workspaces').fetchone()[0]
            db.execute("INSERT INTO workspace_state VALUES (?, 1, 7, ?, 'original')", (identity, '{"version":1,"applications":[],"saved":"opaque"}'))
        elif owner == 'sync':
            identity = 'owner'
            db.execute("INSERT INTO bee_sync_feeds VALUES ('owner', 'feed', 1, 1, 16, 16)")
            db.execute("INSERT INTO bee_sync_projections VALUES ('owner', 'feed', 'saved', 1, ?, 0, 1, 'original')", ('{"saved":"opaque"}',))
        else:
            identity = db.execute('SELECT client_id FROM client_state').fetchone()[0]
        return identity


def run(project, state, owner, failure=None):
    result = subprocess.run([str(RUNTIME), 'run', '--host', 'bee:terminal', '--set', f'registry.history_path={state / "registry.db"}', '--override', 'bee.sync.service:sync_distribution_service:lifecycle.auto_start=false', 'persist-probe', owner],
                            cwd=project, env=database_environment(state), capture_output=True, text=True, timeout=90)
    output = result.stdout + result.stderr
    if failure:
        assert result.returncode and failure in output, output
    else:
        assert result.returncode == 0, output
    label = owner.removeprefix('history-')
    label = 'thread' if label == 'threads' else label
    phases = re.findall(r'^PERSIST_BOOT (\w+) (begin|end|failed) (-?\d+)$', output, re.M)
    phases = [(stage, int(elapsed)) for reported, stage, elapsed in phases if reported == label]
    assert [stage for stage, _ in phases] == ['begin', 'failed' if failure else 'end'], output
    assert all(elapsed >= 0 for _, elapsed in phases), output
    return output


def ledger_rows(path, owner):
    with sqlite3.connect(path) as db:
        return db.execute(f'SELECT id, name, checksum FROM {OWNERS[owner][1]} ORDER BY id').fetchall()


def capture_progress(project):
    source = project / 'modules/persist/src/persist/ledger.lua'
    text = source.read_text().replace('local env = require("env")\n', '')
    text = text.replace('local hash = require("hash")', '''local hash = require("hash")
local captured: {string} = {}
local env = {
    get = function(_name: string): string return "active" end,
    set = function(_name: string, phase: string) table.insert(captured, phase) end,
}''')
    text = text.replace('local logger = require("logger")', '''local boot_phases: {string} = {}
local logger = {
    named = function(_self: unknown, _name: string)
        return {info = function(_self: unknown, message: string,
            fields: {phase: string, stage: string, owner: string, elapsed_ms: integer?})
            assert(message == "Boot phase" and fields.phase == "migration_check")
            table.insert(boot_phases, fields.owner .. " " .. fields.stage .. " " .. tostring(fields.elapsed_ms or 0))
        end}
    end,
}''')
    text = text.replace('local M = {}', 'local M = {}\nfunction M.progress(): {string} return captured end\nfunction M.boot_phases(): {string} return boot_phases end')
    source.write_text(text)


def progress(output, owner, start, end, batch):
    phases = re.findall(r'^PERSIST_PROGRESS (.+)$', output, re.M)
    phases = [phase for phase in phases if phase.split(': ', 1)[1].split()[0] == owner]
    assert phases and phases[0] == f'Checking data: {owner}', phases
    for revision in range(1, start + 1):
        assert f'Checking data: {owner} {revision}/{end}' in phases, phases
    pending = []
    for revision in range(start + 1, end + 1):
        pending += [f'Upgrading data: {owner} {revision - 1}->{revision}',
                    f'Applied data: {owner} {revision}']
        if not batch:
            pending.append(f'Upgraded data: {owner} {revision - 1}->{revision}')
    if batch and start < end:
        pending.append(f'Upgraded data: {owner} {end - 1}->{end}')
    assert [phase for phase in phases if not phase.startswith('Checking data: ')] == pending, phases


def fault(project, owner, step):
    source = project / 'modules/persist/src/persist/ledger.lua'
    original = source.read_text()
    table = OWNERS[owner][1]
    replacement = f'''    if not apply_err and ledger.table == "{table}" and migration.id == {step} then
        local io = require("io")
        local channel = require("channel")
        for _, phase in ipairs(M.progress()) do assert(io.print("PERSIST_PROGRESS " .. phase)) end
        assert(io.print("PERSIST_CRASH_READY"))
        local barrier = channel.new()
        barrier:receive()
    end
'''
    source.write_text(original.replace('    if apply_err then return', replacement + '    if apply_err then return', 1))
    manifest = project / 'modules/persist/src/persist/_index.yaml'
    original_manifest = manifest.read_text()
    document = yaml.safe_load(original_manifest)
    next(entry for entry in document['entries'] if entry['name'] == 'ledger')['modules'] += ['io', 'channel']
    manifest.write_text(yaml.safe_dump(document, sort_keys=False))
    return source, original, manifest, original_manifest


def crash(project, state, owner, step):
    source, original, manifest, original_manifest = fault(project, owner, step)
    process = subprocess.Popen([str(RUNTIME), 'run', '--host', 'bee:terminal', '--set', f'registry.history_path={state / "registry.db"}', '--override', 'bee.sync.service:sync_distribution_service:lifecycle.auto_start=false', 'persist-probe', owner],
                               cwd=project, env=database_environment(state), stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    output = bytearray()
    try:
        deadline = time.monotonic() + 90
        while b'PERSIST_CRASH_READY' not in output:
            assert time.monotonic() < deadline, output.decode(errors='replace')
            ready, _, _ = select.select([process.stdout], [], [], min(1, max(0, deadline - time.monotonic())))
            if ready:
                block = os.read(process.stdout.fileno(), 65536)
                assert block, output.decode(errors='replace')
                output.extend(block)
        phases = output.decode(errors='replace')
        assert f'PERSIST_PROGRESS Upgrading data: {owner} {step - 1}->{step}' in phases, phases
        assert f'PERSIST_PROGRESS Upgraded data: {owner} {step - 1}->{step}' not in phases, phases
        if owner != 'sync':
            assert f'PERSIST_PROGRESS Upgraded data: {owner}' not in phases, phases
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        process.stdout.close()
        source.write_text(original)
        manifest.write_text(original_manifest)


def diagnostic_failure(project, state, owner):
    source = project / 'modules/persist/src/persist/ledger.lua'
    original = source.read_text()
    table = OWNERS[owner][1]
    injection = f'''    if not apply_err and ledger.table == "{table}" and migration.id == 1 then
        _, apply_err = tx:execute([[CREATE TABLE diagnostic_abort (value INTEGER);
CREATE TRIGGER diagnostic_abort_trigger BEFORE INSERT ON diagnostic_abort
BEGIN SELECT RAISE(ROLLBACK, 'native startup migration abort'); END;
INSERT INTO diagnostic_abort VALUES (1)]])
    end
'''
    source.write_text(original.replace('    if apply_err then return', injection + '    if apply_err then return', 1))
    try:
        output = run(project, state, owner, 'native startup migration abort')
    finally:
        source.write_text(original)
    phases = re.findall(r'^PERSIST_PROGRESS (.+)$', output, re.M)
    assert f'Upgrading data: {owner} 0->1' in phases, output
    assert not any(phase.startswith(('Applied data:', 'Upgraded data:')) for phase in phases), output
    operation = f'apply {"Client" if owner == "client" else owner} migration '
    native_message, cleanup = 'native startup migration abort', '; rollback migration:'
    assert all(message in output for message in (operation, native_message, cleanup)), output
    assert output.index(operation) < output.index(native_message) < output.index(cleanup), output
    with sqlite3.connect(state / (owner + '.db')) as db:
        assert db.execute("SELECT count(*) FROM sqlite_master WHERE name = 'diagnostic_abort'").fetchone() == (0,)
        if owner == 'sync':
            assert db.execute(f'SELECT count(*) FROM {table}').fetchone() == (0,)
        else:
            assert db.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table'").fetchone() == (0,)
    print(f'{owner}: active checkpoint retains operation/native/rollback diagnostics without announcing completion', flush=True)


def catalog_snapshot(path):
    with sqlite3.connect(path) as db:
        tables = ('workspaces', 'workspace_state', 'workspace_display_assignments',
                  'workspace_display_transfer_receipts', 'workspace_application_thread_bindings', 'workspace_folder')
        aliases = dict(zip(
            ('bee.settings', 'bee.console', 'bee.host.processes', 'bee.gov.overlays', 'bee.threads.timeline',
             'bee.workspace.manager', 'bee.hive.manager', 'bee.hive_manager', 'bee.inbox', 'bee.modules',
             'bee.hub.modules', 'bee.overlays', 'bee.workspaces', 'bee.timeline', 'bee.processes', 'bee.approvals.inbox'),
            ('bee.settings', 'bee.console', 'bee.host.processes', 'bee.gov.overlays', 'bee.threads.timeline',
             'bee.workspace.manager', 'bee.hive.manager', 'bee.hive.manager', 'bee.approvals.inbox', 'bee.hub.modules',
             'bee.hub.modules', 'bee.gov.overlays', 'bee.workspace.manager', 'bee.threads.timeline', 'bee.host.processes', 'bee.approvals.inbox')))
        aliases = {old + ':app': new + '.app:app' for old, new in aliases.items()}
        result = {}
        for table in tables:
            columns = [row[1] for row in db.execute(f'PRAGMA table_info({table})')]
            rows = [dict(zip(columns, row)) for row in db.execute(f'SELECT * FROM {table} ORDER BY 1')]
            for row in rows:
                if table == 'workspace_application_thread_bindings':
                    row['definition_id'] = aliases.get(row['definition_id'], row['definition_id'])
                elif table == 'workspace_state':
                    value = json.loads(row['value'])
                    for app in value.get('applications', []):
                        if 'definition_id' in app:
                            app['definition_id'] = aliases.get(app['definition_id'], app['definition_id'])
                    row['value'] = value
            result[table] = rows
        return result


def upgrade_nine(project, state, path):
    before = ledger_rows(path, 'workspace')
    assert [row[0] for row in before] == list(range(1, 10))
    catalog = catalog_snapshot(path)
    started = time.monotonic()
    output = run(project, state, 'workspace')
    elapsed = time.monotonic() - started
    progress(output, 'workspace', 9, 14, True)
    after = ledger_rows(path, 'workspace')
    assert after[:9] == before and len(after) == 14
    assert catalog_snapshot(path) == catalog
    with sqlite3.connect(path) as db:
        assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
    print(f'workspace 9->14: original ledger rows and catalog/state/assignments/bindings/folder intact ({elapsed:.3f}s)', flush=True)


def startup_failure():
    with fixture_workspace(unit_tests=False) as project:
        from workspace import name_node
        name_node(project, 'migration-startup')
        state = project / '.wippy'
        path = state / 'workspace.db'
        seed(path, 'workspace', workspace_revision=9)
        with sqlite3.connect(path) as db:
            db.execute("UPDATE workspace_schema_migrations SET checksum = 'unknown' WHERE id = 9")
        config = project / 'desktop-admission.yaml'
        config.write_text(yaml.safe_dump({'version': '1.0', 'override': {
            'bee.hive.service:supervisor_service:input': [{'configured_nodes': [], 'desktop': {
                'execution': 'a' * 32, 'expires_at': '2099-01-01T00:00:00.000Z',
                'allowed_nodes': [], 'local_clients': True}}]}}))
        owner = project / 'src/launch/owner.lua'
        owner_source = owner.read_text()
        owner_source = owner_source.replace('if failure then error(failure) end',
            'if failure then assert(io.print("OWNER_STARTUP_FAILURE_MS " .. tostring(startup_now_ms()))); error(failure) end', 1)
        owner_source = owner_source.replace('if reason then error(reason) end',
            'if reason then assert(io.print("OWNER_STARTUP_FAILURE_MS " .. tostring(startup_now_ms()))); error(reason) end', 1)
        owner.write_text(owner_source)
        started = time.monotonic()
        result = subprocess.run([str(RUNTIME), 'run', '--verbose', '--host', 'bee:terminal',
            '--config', '.wippy.yaml', '--config', str(config), '--', 'bee-owner'],
            cwd=project, env=database_environment(state), capture_output=True, text=True, timeout=20)
        elapsed = time.monotonic() - started
        output = result.stdout + result.stderr
        expected = declared_migrations((ROOT / 'modules/workspace/src/migrations/migrations.lua').read_text())[8]
        digest = hashlib.sha256((expected[1] + '\n' + expected[2]).encode()).hexdigest()
        message = f'workspace migration 9 (nested_bee_names_v1) checksum changed: expected {digest}, found unknown'
        assert result.returncode and message in output, output
        assert 'Hive supervisor failed before retained workspace readiness:' in output, output
        assert 'startup stalled' not in output, output
        measured = re.search(r'^OWNER_STARTUP_FAILURE_MS (\d+)$', output, re.M)
        assert measured and int(measured[1]) < 1000, output
        assert len(ledger_rows(path, 'workspace')) == 9
        print(f'Owner startup reports exact unknown-checksum diagnostic in {measured[1]}ms of its startup flow ({elapsed:.3f}s including boot)', flush=True)


def equivalent_nine(project, select_db):
    baseline = project / '.wippy' / 'equivalence-base.db'
    seed(baseline, 'workspace', workspace_revision=8)
    with sqlite3.connect(baseline) as db:
        value = {'version': 1, 'applications': [{'definition_id': 'bee.inbox:app', 'saved': {'x': 1, 'definition_id': 'bee.inbox:app'}},
                                              {'definition_id': 'bee.console.app:app'}, {'opaque': {'unrelated': True}}], 'saved': {'definition_id': 'bee.inbox:app', 'payload': 'opaque'}}
        db.execute('UPDATE workspace_state SET value = ?', (json.dumps(value, separators=(', ', ':')),))
        columns = [row[1] for row in db.execute('PRAGMA table_info(workspace_application_thread_bindings)')]
        row = dict(workspace_id=db.execute('SELECT workspace_id FROM workspaces').fetchone()[0],
            instance_id='inbox', thread_id='thread', definition_id='bee.inbox:app', actor_id='actor',
            role='participant', binding_revision=1, state='revoked', idempotency_key='inbox',
            definition_revision='v1', initiating_owner_id='owner', gateway_binding_id='gateway',
            gateway_approval_id='approval', gateway_proposal_digest='a' * 64, access='observe_post',
            join_expected_revision=1, membership_revision=None, cleanup_pending=0, cleanup_expected_revision=None)
        db.execute(f'INSERT INTO workspace_application_thread_bindings ({",".join(columns)}) VALUES ({",".join("?" for _ in columns)})', [row.get(key) for key in columns])
    snapshots = []
    for original in (True, False):
        state = project / '.wippy' / ('equivalence-original' if original else 'equivalence-edited')
        path = select_db('workspace', state)
        shutil.copy2(baseline, path)
        identity, name, sql = declared_migrations((ROOT / 'modules/workspace/src/migrations/migrations.lua').read_text())[8]
        if original:
            sql = sql.replace('bee.approvals.inbox.app:app', 'bee.approvals.inbox:app')
        with sqlite3.connect(path) as db:
            db.executescript(sql)
            db.execute('INSERT INTO workspace_schema_migrations VALUES (?, ?, ?, ?)',
                (identity, name, hashlib.sha256((name + '\n' + sql).encode()).hexdigest(), 'original'))
        run(project, state, 'workspace')
        with sqlite3.connect(path) as db:
            assert db.execute('SELECT definition_id FROM workspace_application_thread_bindings').fetchone() == ('bee.approvals.inbox.app:app',)
            value = json.loads(db.execute('SELECT value FROM workspace_state').fetchone()[0])
            assert value['applications'][0]['definition_id'] == 'bee.approvals.inbox.app:app'
            assert value['applications'][2] == {'opaque': {'unrelated': True}}
            assert value['applications'][0]['saved']['definition_id'] == 'bee.approvals.inbox.app:app'
            assert value['saved'] == {'definition_id': 'bee.approvals.inbox.app:app', 'payload': 'opaque'}
            schema = db.execute("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        snapshots.append((schema, catalog_snapshot(path)))
        before = snapshots[-1]
        run(project, state, 'workspace')
        assert catalog_snapshot(path) == before[1]
    assert snapshots[0] == snapshots[1]
    print('Fresh original/edited migration 9 histories converge to identical schema and populated inbox data; reopen is idempotent', flush=True)


def copy_equivalence(project, select_db, source, upgraded):
    from test_migration_histories import snapshot
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as db:
        schema, data = snapshot(db)
        ledger_schema = next(row[2] for row in schema if row[1] == 'workspace_schema_migrations')
        del data['workspace_schema_migrations']
    with sqlite3.connect(upgraded) as db:
        expected_schema, expected_data = snapshot(db)
        del expected_data['workspace_schema_migrations']
    for original in (True, False):
        state = project / '.wippy' / f'copy-equivalence-{original}'
        path = select_db('workspace', state)
        seed(path, 'workspace', workspace_revision=8)
        with sqlite3.connect(path) as db:
            ledger = db.execute('SELECT * FROM workspace_schema_migrations ORDER BY id').fetchall()
            db.execute('DROP TABLE workspace_schema_migrations')
            db.execute(ledger_schema)
            db.executemany('INSERT INTO workspace_schema_migrations VALUES (?, ?, ?, ?)', ledger)
            for table, rows in data.items():
                db.execute(f'DELETE FROM {table}')
                for row in rows:
                    values = []
                    for value in row:
                        if isinstance(value, str):
                            value = value.replace('bee.approvals.inbox:app', 'bee.inbox:app')
                        values.append(value)
                    db.execute(f'INSERT INTO {table} VALUES ({",".join("?" for _ in values)})', values)
            identity, name, sql = declared_migrations((ROOT / 'modules/workspace/src/migrations/migrations.lua').read_text())[8]
            if original:
                sql = sql.replace('bee.approvals.inbox.app:app', 'bee.approvals.inbox:app')
            db.executescript(sql)
            db.execute('INSERT INTO workspace_schema_migrations VALUES (?, ?, ?, ?)',
                (identity, name, hashlib.sha256((name + '\n' + sql).encode()).hexdigest(), 'original'))
        run(project, state, 'workspace')
        with sqlite3.connect(path) as db:
            actual_schema, actual_data = snapshot(db)
            del actual_data['workspace_schema_migrations']
        assert actual_schema == expected_schema
        assert actual_data == expected_data
    print('User copy and fresh original/edited migration 9 histories end with identical schema and raw owner data (ledger history preserved separately)', flush=True)


def workspace_root_histories(project, select_db):
    from test_migration_histories import HISTORY, snapshot
    expected = declared_migrations((ROOT / 'modules/workspace/src/migrations/migrations.lua').read_text())
    for fresh in (False, True):
        snapshots = []
        for original in (True, False):
            state = project / '.wippy' / f'workspace-roots-{fresh}-{original}'
            path = select_db('workspace', state)
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE workspace_schema_migrations (id INTEGER PRIMARY KEY CHECK (id > 0), name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)')
                db.execute('CREATE TEMP TABLE workspace_migration_run (fresh INTEGER)')
                db.execute('INSERT INTO workspace_migration_run VALUES (?)', (int(fresh),))
                for identity, name, current in expected[:9]:
                    old = HISTORY / f'workspace_{identity}.sql'
                    sql = old.read_text() if original and old.exists() else current
                    db.executescript(sql)
                    db.execute('INSERT INTO workspace_schema_migrations VALUES (?, ?, ?, ?)',
                        (identity, name, hashlib.sha256((name + '\n' + sql).encode()).hexdigest(), 'original'))
                    if identity == 2:
                        db.execute('UPDATE workspace_identity SET workspace_id = ?', ('a' * 32,))
                    if identity == 6:
                        db.execute("UPDATE workspaces SET created_at='saved', last_used_at='saved'")
                if not fresh:
                    db.execute("INSERT INTO workspace_state VALUES (?, 1, 7, ?, 'saved')", ('a' * 32, '{"version":1,"saved":"opaque"}'))
                before = db.execute('SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id').fetchall()
            run(project, state, 'workspace')
            assert ledger_rows(path, 'workspace')[:9] == before
            with sqlite3.connect(path) as db:
                schema, data = snapshot(db)
                del data['workspace_schema_migrations']
                snapshots.append((schema, data))
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
        assert snapshots[0] == snapshots[1]
    print('Workspace original/edited 6/8/9 histories converge through the real store for fresh and retained folder catalogs', flush=True)


def owner_histories(project, probe):
    from test_migration_histories import SOURCES, HISTORY, snapshot, populate
    for owner in ('threads', 'governance', 'gateway', 'sync'):
        expected = declared_migrations((ROOT / SOURCES[owner]).read_text())
        originals = {int(path.stem.split('_')[-1]): path.read_text() for path in HISTORY.glob(owner + '_*.sql')}
        limit = max(originals)
        snapshots = []
        table = {'threads': 'bee_thread_schema_migrations', 'governance': 'bee_governance_migrations',
                 'gateway': 'bee_gateway_schema_migrations', 'sync': 'bee_sync_schema_migrations'}[owner]
        main_source = subprocess.check_output(['git', 'show', 'origin/main:' + SOURCES[owner]], cwd=ROOT, text=True)
        for variant in ('original', 'edited', 'main'):
            original = variant == 'original'
            applied = declared_migrations(main_source) if variant == 'main' else expected[:limit]
            state = project / '.wippy' / f'history-{owner}-{variant}'
            state.mkdir()
            path = state / 'history.db'
            with sqlite3.connect(path) as db:
                db.execute(f'CREATE TABLE {table} (id INTEGER PRIMARY KEY CHECK (id > 0), name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)')
                for identity, name, current in applied:
                    sql = originals.get(identity, current) if original else current
                    db.executescript(sql)
                    db.execute(f'INSERT INTO {table} VALUES (?, ?, ?, ?)',
                        (identity, name, hashlib.sha256((name + '\n' + sql).encode()).hexdigest(), 'original'))
                populate(db, owner, original)
                before = db.execute(f'SELECT * FROM {table} ORDER BY id').fetchall()
            index = probe / '_index.yaml'
            document = yaml.safe_load(index.read_text())
            document['entries'] = [entry for entry in document['entries'] if entry['name'] != 'history']
            document['entries'].append({'name': 'history', 'kind': 'db.sql.sqlite', 'file': str(path), 'lifecycle': {'auto_start': True}})
            index.write_text(yaml.safe_dump(document, sort_keys=False))
            # Use the shared real runner with the owning component's unchanged migration list.
            run(project, state, 'history-' + owner)
            with sqlite3.connect(path) as db:
                after = db.execute(f'SELECT * FROM {table} ORDER BY id').fetchall()
                assert after[:len(applied)] == before and len(after) == len(expected)
                assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
                schema, data = snapshot(db)
                del data[table]
                snapshots.append((schema, data))
            run(project, state, 'history-' + owner)
            with sqlite3.connect(path) as db:
                assert db.execute(f'SELECT * FROM {table} ORDER BY id').fetchall() == after
        assert all(value == snapshots[0] for value in snapshots[1:]), owner
        print(f'{owner}: real runner original/edited/main shipped histories converge with data and ledger rows preserved', flush=True)


def main(workspace_copy=None, upgrade_only=False):
    bytes_check()
    with fixture_workspace(unit_tests=False) as project:
        capture_progress(project)
        probe = project / 'src/persistprobe'
        probe.mkdir()
        (probe / 'main.lua').write_text(PROBE)
        (probe / '_index.yaml').write_text(yaml.safe_dump({
            'version': '1.0', 'namespace': 'bee.persistprobe', 'entries': [
                {'name': 'policy', 'kind': 'security.policy', 'policy': {
                    'actions': ['db.get'], 'resources': [entry[0] for entry in OWNERS.values()] + ['bee.persistprobe:history'], 'effect': 'allow'}},
                {'name': 'main', 'kind': 'process.lua', 'source': 'file://main.lua', 'method': 'main',
                 'modules': ['io', 'sql'],
                 'imports': {'workspace': 'bee.workspace.persist:store', 'client': 'bee.client.persist:store', 'sync': 'bee.sync.persist:database', 'ledger': 'bee.persist.persist:ledger',
                     'threads_migrations': 'bee.threads.migrations:migrations',
                     'governance_migrations': 'bee.gov.migrations:schema',
                     'gateway_migrations': 'bee.gateway.migrations:migrations',
                     'sync_migrations': 'bee.sync.migrations:migrations'},
                 'meta': {'command': {'name': 'persist-probe', 'short': 'migration recovery fixture'}},
                 'security': {'policies': ['bee.persistprobe:policy']}}]}))
        manifests = {}
        for owner, (resource, _, _) in OWNERS.items():
            namespace, name = resource.split(':')
            directory = project / 'src' / owner / 'db' if owner != 'sync' else project / 'modules/sync/src'
            directory.mkdir(parents=True, exist_ok=True)
            document = {'version': '1.0', 'namespace': namespace, 'entries': [{
                'name': name, 'kind': 'db.sql.sqlite', 'file': f'.wippy/{owner}.db',
                'lifecycle': {'auto_start': True}}]}
            manifests[owner] = directory / '_index.yaml'
            if manifests[owner].exists():
                existing = yaml.safe_load(manifests[owner].read_text())
                existing['entries'] += document['entries']
                document = existing
            manifests[owner].write_text(yaml.safe_dump(document))

        def select_db(owner, state):
            state.mkdir(parents=True, exist_ok=True)
            document = yaml.safe_load(manifests[owner].read_text())
            next(entry for entry in document['entries'] if entry['name'] == 'runner')['file'] = str(state / (owner + '.db'))
            manifests[owner].write_text(yaml.safe_dump(document))
            return state / (owner + '.db')

        equivalent_nine(project, select_db)
        state = project / '.wippy' / 'upgrade-nine-workspace'
        path = select_db('workspace', state)
        seed(path, 'workspace', workspace_revision=9)
        upgrade_nine(project, state, path)
        if workspace_copy is not None:
            state = project / '.wippy' / 'catalog-copy-workspace'
            path = select_db('workspace', state)
            shutil.copy2(workspace_copy, path)
            upgrade_nine(project, state, path)
            shutil.copy2(path, ROOT / '.wippy/wsfix/result.db')
            copy_equivalence(project, select_db, workspace_copy, path)
        if upgrade_only:
            return
        workspace_root_histories(project, select_db)
        owner_histories(project, probe)

        for owner in OWNERS:
            state = project / '.wippy' / ('diagnostic-' + owner)
            select_db(owner, state)
            diagnostic_failure(project, state, owner)

            state = project / '.wippy' / ('fresh-' + owner)
            path = select_db(owner, state)
            progress(run(project, state, owner), owner, 0, OWNERS[owner][2], owner != 'sync')
            original = ledger_rows(path, owner)
            assert len(original) == OWNERS[owner][2]
            progress(run(project, state, owner), owner, OWNERS[owner][2], OWNERS[owner][2], owner != 'sync')
            assert ledger_rows(path, owner) == original
            with sqlite3.connect(path) as db:
                db.execute(f"UPDATE {OWNERS[owner][1]} SET checksum = 'changed' WHERE id = 1")
            rejected = run(project, state, owner, 'checksum changed')
            assert f'PERSIST_PROGRESS Checking data: {owner}' in rejected, rejected
            assert not re.search(r'PERSIST_PROGRESS (?:Upgrading|Applied|Upgraded) data:', rejected), rejected
            with sqlite3.connect(path) as db:
                db.execute(f'UPDATE {OWNERS[owner][1]} SET checksum = ? WHERE id = 1', (original[0][2],))
            if owner == 'workspace':
                with sqlite3.connect(path) as db:
                    assert db.execute('SELECT created FROM workspace_folder').fetchone() == (0,)
                    assert db.execute('SELECT count(*) FROM workspaces').fetchone() == (0,)

            state = project / '.wippy' / ('concurrent-' + owner)
            path = select_db(owner, state)
            # Registry writers use separate files; the migration database is shared.
            states = [state / str(index) for index in range(4)]
            for child in states:
                child.mkdir()
            with ThreadPoolExecutor(max_workers=4) as workers:
                list(workers.map(lambda child: run(project, child, owner), states))
            assert len(ledger_rows(path, owner)) == OWNERS[owner][2]

            state = project / '.wippy' / ('crash-fresh-' + owner)
            path = select_db(owner, state)
            crash(project, state, owner, 2)
            with sqlite3.connect(path) as db:
                if owner == 'sync':
                    assert db.execute(f'SELECT count(*) FROM {OWNERS[owner][1]}').fetchone() == (1,)
                else:
                    assert db.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table'").fetchone() == (0,)
            run(project, state, owner)
            assert len(ledger_rows(path, owner)) == OWNERS[owner][2]
            if owner == 'workspace':
                with sqlite3.connect(path) as db:
                    assert db.execute('SELECT created FROM workspace_folder').fetchone() == (0,)
            print(f'{owner}: fresh/reopen, checksum rejection, 4 concurrent opens, mid-migration SIGKILL/recovery pass', flush=True)

            state = project / '.wippy' / ('upgrade-' + owner)
            path = select_db(owner, state)
            identity = seed(path, owner)
            before = ledger_rows(path, owner)
            crash(project, state, owner, 8 if owner == 'workspace' else 2)
            assert ledger_rows(path, owner) == before
            progress(run(project, state, owner), owner, len(before), OWNERS[owner][2], owner != 'sync')
            after = ledger_rows(path, owner)
            assert after[:len(before)] == before
            with sqlite3.connect(path) as db:
                if owner == 'workspace':
                    assert db.execute('SELECT workspace_id FROM workspaces').fetchone() == (identity,)
                    assert db.execute('SELECT generation, value FROM workspace_state').fetchone() == (7, '{"version":1,"applications":[],"saved":"opaque"}')
                    assert db.execute('SELECT created FROM workspace_folder').fetchone() == (1,)
                elif owner == 'sync':
                    assert db.execute("SELECT value_json FROM bee_sync_projections WHERE owner_id = 'owner'").fetchone() == ('{"saved":"opaque"}',)
                else:
                    assert db.execute('SELECT client_id FROM client_state').fetchone() == (identity,)
                    assert len(db.execute('PRAGMA table_info(client_schema_migrations)').fetchall()) == 3
            print(f'{owner}: populated old database, crash during upgrade, identity/data/checksum preservation pass', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace-copy', type=Path)
    parser.add_argument('--upgrade-only', action='store_true')
    parser.add_argument('--startup-only', action='store_true')
    args = parser.parse_args()
    if args.startup_only:
        startup_failure()
    else:
        main(args.workspace_copy, args.upgrade_only)
        if not args.upgrade_only:
            startup_failure()
