"""Immutable shipped SQL histories converge without changing applied text."""
from pathlib import Path
import json
import re
import sqlite3
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
HISTORY = ROOT / 'tests/fixtures/migration_history'
SOURCES = {
    'workspace': 'modules/workspace/src/migrations/migrations.lua',
    'threads': 'modules/threads/src/migrations/migrations.lua',
    'governance': 'modules/gov/src/migrations/schema.lua',
    'gateway': 'modules/gateway/src/migrations/migrations.lua',
    'sync': 'modules/sync/src/migrations/migrations.lua',
}
ALL_SOURCES = {
    **SOURCES,
    'approvals': 'modules/approvals/src/migrations/migrations.lua',
    'client': 'modules/client/src/migrations/migrations.lua',
    'credentials': 'modules/credentials/src/migrations/migrations.lua',
    'placement': 'modules/placement-native/src/migrations/migrations.lua',
    'resources': 'modules/resources/src/migrations/migrations.lua',
}


def migrations(source):
    token = r'\[\[.*?\]\]|"(?:[^"\\]|\\.)*"|\w+'
    expression = r'(?:' + token + r')(?:\s*\.\.\s*(?:' + token + r'))*'
    constants = dict(re.findall(r'local (\w+) = (' + expression + r')', source, re.S))

    def resolve(expr):
        values = []
        for part in re.findall(token, expr, re.S):
            if part.startswith('[['):
                values.append(part[2:-2].removeprefix('\n'))
            elif part.startswith('"'):
                values.append(json.loads(part))
            else:
                values.append(resolve(constants[part]))
        return ''.join(values)

    result = []
    for match in re.finditer(r'\{id\s*=\s*(\d+),\s*name\s*=\s*"([^"]+)"', source):
        identity, name = match.groups()
        tail = source[match.end():]
        expr = re.search(r'\bsql\s*=\s*(' + expression + r')', tail, re.S)[1]
        result.append((int(identity), name, resolve(expr)))
    return result


def snapshot(db):
    schema = db.execute("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
    tables = [row[1] for row in schema if row[0] == 'table']
    return schema, {table: db.execute(f'SELECT * FROM {table} ORDER BY 1').fetchall() for table in tables}


def populate(db, owner, original, *, telemetry_service='bee.hive.telemetry.binding'):
    telemetry_owner = json.dumps({'owner_ref': {'service_id': telemetry_service}}, separators=(',', ':'))
    if owner == 'threads':
        db.execute("INSERT INTO bee_thread_heads (thread_id, owner_actor, title, state, revision, created_at) VALUES ('thread', 'actor', 'saved', 'open', 1, 'saved')")
        db.execute("INSERT INTO bee_thread_records (record_id, thread_id, sequence, schema_revision, kind, producer_id, source, record_json, committed_at) VALUES ('record', 'thread', 1, 'bee.thread-record@1', 'action.admitted', 'actor', 'bee', '{}', 'saved')")
        db.execute("INSERT INTO bee_thread_actions VALUES ('thread', 'action', 'record', 'admitted')")
        db.execute("INSERT INTO bee_thread_attempts (thread_id, attempt_id, action_id, state) VALUES ('thread', 'attempt', 'action', 'prepared')")
        db.execute("INSERT INTO bee_thread_cancel_intents VALUES ('thread', 'attempt', 'key', 'cancelling', NULL, 'saved', 'saved')")
    elif owner == 'governance':
        db.execute("INSERT INTO bee_governance_leases (owner_node, workspace_id, lease_id, target, envelope_bytes, envelope_digest, source_approval_id, source_approval_proposal_digest, source_approval_owner_incarnation, granted_by, created_at, max_applies, applies_used, revision, state) VALUES ('node', 'workspace', 'lease', 'target', '{}', ?, 'approval', ?, 1, 'actor', 'saved', 3, 1, 1, 'active')", ('a' * 64, 'b' * 64))
        columns = 'owner_node, workspace_id, lease_id, intent_id, proposal_snapshot_bytes, proposal_snapshot_digest, applied_at'
        values = ['node', 'workspace', 'lease', 'intent', '{}', 'c' * 64, 'saved']
        if not original:
            columns += ', approval_id, approval_proposal_digest, state, admitted_at'
            values += ['approval', 'b' * 64, 'admitted', 'saved']
        db.execute(f'INSERT INTO bee_governance_lease_uses ({columns}) VALUES ({",".join("?" for _ in values)})', values)
    elif owner == 'gateway':
        db.execute("INSERT INTO bee_gateway_bindings (binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, epoch, credential_generation, expires_at, created_at) VALUES ('binding', 'actor', 'action', 'attempt', 'thread', 1, 1, '[]', 1, 1, '2099-01-01T00:00:00.000Z', 'saved')")
        db.execute("INSERT INTO bee_gateway_surfaces VALUES ('binding', ?, ?, '{}', 1)", (telemetry_owner, telemetry_owner))
        db.execute("INSERT INTO bee_gateway_access_grants VALUES ('binding', 'approval', ?, ?)", ('a' * 64, '[' + telemetry_owner + ']'))
    elif owner == 'sync':
        db.execute("INSERT INTO bee_sync_feeds VALUES ('owner', 'feed', 1, 1, 16, 16)")
        db.execute("INSERT INTO bee_sync_projections VALUES ('owner', 'feed', 'projection', 1, ?, 0, 1, 'saved')", (telemetry_owner,))
        db.execute("INSERT INTO bee_sync_events VALUES ('owner', 'feed', 1, 'event', 'changed', ?, 'projection', 1, 0, 'saved')", (telemetry_owner,))
        db.execute("INSERT INTO bee_sync_receipts VALUES ('owner', 'feed', 'key', 'event', ?, 1, 'projection', 1)", (telemetry_owner,))


class MigrationHistories(unittest.TestCase):
    def test_main_migrations_remain_an_unchanged_prefix(self):
        for owner, path in ALL_SOURCES.items():
            with self.subTest(owner=owner):
                prior_path = path
                if owner == 'client' and subprocess.run(
                    ['git', 'cat-file', '-e', 'origin/main:' + path], cwd=ROOT,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                ).returncode:
                    prior_path = 'src/client/store.lua'
                prior = subprocess.check_output(['git', 'show', 'origin/main:' + prior_path], cwd=ROOT, text=True)
                shipped = migrations(prior)
                self.assertEqual(migrations((ROOT / path).read_text())[:len(shipped)], shipped)

    def test_every_store_has_unique_ordered_migration_ids(self):
        for owner, path in ALL_SOURCES.items():
            with self.subTest(owner=owner):
                identities = [identity for identity, _, _ in migrations((ROOT / path).read_text())]
                self.assertEqual(identities, list(range(1, len(identities) + 1)))

    def test_populated_current_telemetry_rows_survive_migration_replay(self):
        for owner in ('gateway', 'sync'):
            snapshots = []
            current = migrations((ROOT / SOURCES[owner]).read_text())
            for service in ('bee.hive.telemetry', 'bee.hive.telemetry.binding'):
                with self.subTest(owner=owner, service=service), sqlite3.connect(':memory:') as db:
                    for _, _, sql in current:
                        db.executescript(sql)
                    populate(db, owner, False, telemetry_service=service)
                    before = snapshot(db)
                    repair = {'gateway': 18, 'sync': 10}[owner]
                    for identity, _, sql in current:
                        if identity >= repair:
                            db.executescript(sql)
                    after = snapshot(db)
                    if service == 'bee.hive.telemetry.binding':
                        self.assertEqual(after, before)
                    snapshots.append(after)
            self.assertEqual(snapshots[0], snapshots[1], owner)

    def test_governance_repair_preserves_reserved_and_fenced_approval_fields(self):
        current = migrations((ROOT / SOURCES['governance']).read_text())
        with sqlite3.connect(':memory:') as db:
            for _, _, sql in current[:15]:
                db.executescript(sql)
            populate(db, 'governance', False)
            db.execute("UPDATE bee_governance_lease_uses SET state='reserved', admitted_at=NULL, approval_id='per-intent', approval_proposal_digest=?", ('d' * 64,))
            db.execute("INSERT INTO bee_governance_lease_uses SELECT owner_node, workspace_id, lease_id, 'fenced-intent', approval_id, approval_proposal_digest, proposal_snapshot_bytes, proposal_snapshot_digest, 'fenced', applied_at, NULL FROM bee_governance_lease_uses")
            before = db.execute('SELECT * FROM bee_governance_lease_uses ORDER BY intent_id').fetchall()
            db.executescript(current[15][2])
            self.assertEqual(db.execute('SELECT * FROM bee_governance_lease_uses ORDER BY intent_id').fetchall(), before)


    def test_all_shipped_variants_converge(self):
        for owner, source in SOURCES.items():
            current = migrations((ROOT / source).read_text())
            originals = {int(path.stem.split('_')[-1]): path.read_text() for path in HISTORY.glob(owner + '_*.sql')}
            snapshots = []
            for original in (True, False):
                with self.subTest(owner=owner, original=original), sqlite3.connect(':memory:') as db:
                    db.execute('CREATE TEMP TABLE workspace_migration_run (fresh INTEGER)')
                    db.execute('INSERT INTO workspace_migration_run VALUES (0)')
                    last_original = max(originals)
                    for identity, name, sql in current:
                        db.executescript(originals.get(identity, sql) if original else sql)
                        if identity == last_original and owner != 'workspace':
                            populate(db, owner, original, telemetry_service='bee.hive.telemetry')
                        if owner == 'workspace' and identity == 2:
                            db.execute("UPDATE workspace_identity SET workspace_id = ?", ('a' * 32,))
                        if owner == 'workspace' and identity == 6:
                            db.execute("UPDATE workspaces SET created_at = 'saved', last_used_at = 'saved'")
                    self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
                    before = snapshot(db)
                    repair_start = {'workspace': 13, 'threads': 29, 'governance': 16, 'gateway': 18, 'sync': 10}[owner]
                    for identity, _, sql in current:
                        if identity >= repair_start:
                            db.executescript(sql)
                    self.assertEqual(snapshot(db), before)
                    snapshots.append(before)
            self.assertEqual(snapshots[0], snapshots[1], owner)
