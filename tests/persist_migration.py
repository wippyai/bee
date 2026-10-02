"""Real SQLite migration opens, concurrent writers and SIGKILL recovery."""
from concurrent.futures import ThreadPoolExecutor
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
    'workspace': ('bee.workspace.db:runner', 'workspace_schema_migrations', 12),
    'client': ('bee.client.db:runner', 'client_schema_migrations', 3),
    'sync': ('bee.sync:runner', 'bee_sync_schema_migrations', len(re.findall(r'\bid = \d+, name =', (ROOT / 'modules/sync/src/migrations/migrations.lua').read_text()))),
}
PROBE = '''local workspace = require("workspace")
local client = require("client")
local sync = require("sync")
local ledger = require("ledger")
local io = require("io")
local function report()
    for _, phase in ipairs(ledger.progress()) do assert(io.print("PERSIST_PROGRESS " .. phase)) end
    for _, phase in ipairs(ledger.boot_phases()) do assert(io.print("PERSIST_BOOT " .. phase)) end
end
local function main(owner: string)
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
    constants = dict(re.findall(r'local (\w+) = \[\[(.*?)\]\]', source, re.S))
    return [(int(identity), name, constants[constant].removeprefix('\n'))
            for identity, name, constant in re.findall(r'\{id = (\d+), name = "([^"]+)", sql = (\w+)', source)]


def bytes_check():
    for path in ['modules/workspace/src/migrations/migrations.lua', 'src/client/store.lua']:
        baseline_path = path
        if path == 'modules/workspace/src/migrations/migrations.lua':
            exists = subprocess.run(['git', 'cat-file', '-e', 'origin/main:' + path], cwd=ROOT,
                capture_output=True, check=False)
            if exists.returncode:
                baseline_path = 'src/storage/store.lua'
        prior = subprocess.check_output(['git', 'show', 'origin/main:' + baseline_path], cwd=ROOT, text=True)
        current = (ROOT / path).read_text()
        assert declared_migrations(current) == declared_migrations(prior), path
    tracked = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', 'origin/main', 'modules'], cwd=ROOT, text=True)
    for path in [ROOT / name for name in tracked.splitlines() if re.search(r'/src/migrations/[^/]+\.lua$', name)]:
        prior = subprocess.check_output(['git', 'show', 'origin/main:' + str(path.relative_to(ROOT))], cwd=ROOT)
        original = prior.decode()
        current = path.read_text()
        for constant, content in re.findall(r'local (\w+) = \[\[(.*?)\]\]', original, re.S):
            found = re.search(r'local ' + constant + r' = \[\[(.*?)\]\]', current, re.S)
            assert found and found[1] == content, (path, constant)
        descriptors = re.findall(r'\{id = \d+, name = "[^"]+",[^}]*\}', original)
        actual = re.findall(r'\{id = \d+, name = "[^"]+",[^}]*\}', current)
        assert actual[:len(descriptors)] == descriptors, path
    print('Workspace 1–12, client 1–3 and all applied owner migration bytes/checksums unchanged; new migrations append', flush=True)


def seed(path, owner):
    if owner == 'sync':
        source = (ROOT / 'modules/sync/src/migrations/migrations.lua').read_text()
        initial = re.search(r'local INITIAL = \[\[(.*?)\]\]', source, re.S)[1].removeprefix('\n')
        expected = [(1, 'owner_local_feed', initial)]
    else:
        source = ROOT / ('modules/workspace/src/migrations/migrations.lua' if owner == 'workspace' else 'src/client/store.lua')
        expected = declared_migrations(source.read_text())
    limit = 7 if owner == 'workspace' else 1
    table = OWNERS[owner][1]
    with sqlite3.connect(path) as db:
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
    phases = re.findall(r'^PERSIST_BOOT (\w+) (begin|end|failed) (-?\d+)$', output, re.M)
    phases = [(stage, int(elapsed)) for label, stage, elapsed in phases if label == owner]
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


def main():
    bytes_check()
    with fixture_workspace(unit_tests=False) as project:
        capture_progress(project)
        probe = project / 'src/persistprobe'
        probe.mkdir()
        (probe / 'main.lua').write_text(PROBE)
        (probe / '_index.yaml').write_text(yaml.safe_dump({
            'version': '1.0', 'namespace': 'bee.persistprobe', 'entries': [
                {'name': 'policy', 'kind': 'security.policy', 'policy': {
                    'actions': ['db.get'], 'resources': [entry[0] for entry in OWNERS.values()], 'effect': 'allow'}},
                {'name': 'main', 'kind': 'process.lua', 'source': 'file://main.lua', 'method': 'main',
                 'modules': ['io'],
                 'imports': {'workspace': 'bee.workspace.persist:store', 'client': 'bee.client:store', 'sync': 'bee.sync.persist:database', 'ledger': 'bee.persist.persist:ledger'},
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
    main()
