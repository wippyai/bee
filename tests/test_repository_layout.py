# SPDX-License-Identifier: MIT
"""Placement rules and persisted callable identity recovery."""
import importlib.util
import json
import re
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SHIPPED_BASELINE = '893d1216'
SPEC = importlib.util.spec_from_file_location('layout_check', ROOT / 'build/layout_check.py')
LAYOUT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAYOUT)


def sql(path, constant="LAYOUT_REFERENCES_SQL"):
    source = (ROOT / path).read_text()
    expression = re.search(r'local ' + constant + r' = (.*?)(?=\n(?:local |function |return ))', source, re.S)
    if not expression:
        raise ValueError("migration constant is missing: " + constant)
    parts = re.split(r'\]\]\s*\.\.\s*(\w+)\s*\.\.\s*\[\[', expression[1])
    result = parts[0].removeprefix('[[')
    for index in range(1, len(parts), 2):
        literal = re.search(r'local ' + parts[index] + r' = \[\[(.*?)\]\]', source, re.S)
        if not literal:
            raise ValueError("migration literal is missing: " + parts[index])
        result += literal[1] + parts[index + 1]
    return result.removesuffix(']]')


class RepositoryLayout(unittest.TestCase):
    def test_repository(self):
        errors, namespaces, entries, targets, dangling = LAYOUT.audit(ROOT)
        self.assertEqual(errors, [])
        self.assertGreater(namespaces, 150)
        self.assertGreater(entries, 1600)
        self.assertGreater(targets, 150)
        self.assertEqual(dangling, 0)

    def test_wrong_folder_or_source_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.wippy', prefix='layout-rule-') as temporary:
            root = Path(temporary)
            source = root / 'src'
            source.mkdir()
            (source / '_index.yaml').write_text("namespace: bee\nentries: []\n")
            misplaced = source / 'threads_hive'
            misplaced.mkdir()
            (misplaced / '_index.yaml').write_text("namespace: bee.threads.hive\nentries:\n- name: helper\n  kind: library.lua\n  source: file://../missing.lua\n")
            errors = LAYOUT.audit(root)[0]
            self.assertTrue(any('folder namespace' in error for error in errors))
            self.assertTrue(any('underscores' in error for error in errors))
            self.assertTrue(any('beside' in error for error in errors))

    def test_append_requirement_has_no_array_default(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.wippy', prefix='layout-append-') as temporary:
            root = Path(temporary)
            source = root / 'src'
            source.mkdir()
            (source / '_index.yaml').write_text('namespace: bee\nentries: []\n')
            module = root / 'modules/example/src'
            module.mkdir(parents=True)
            (module / '_index.yaml').write_text('namespace: bee.example\nentries:\n- name: admission\n  kind: registry.entry\n  bindings: []\n- name: target_admission\n  kind: ns.requirement\n  default: []\n  targets:\n  - entry: bee.example:admission\n    path: .bindings +=\n')
            self.assertTrue(any('append requirement' in error for error in LAYOUT.audit(root)[0]))

    def test_placement_cleanup_recovers_identity_without_changing_opaque_state(self):
        database = sqlite3.connect(':memory:')
        database.executescript('CREATE TABLE bee_placement_preparer_states (attempt_id TEXT, binding_id TEXT, record_json TEXT, PRIMARY KEY(attempt_id, binding_id)); CREATE TABLE bee_placement_evidence (kind TEXT, detail TEXT);')
        state = {'path': '/project/bee.git.worktree:binding', 'token': 'bee.git.worktree.binding:cleanup'}
        record = {'binding_id': 'bee.git_worktree:binding', 'plan': 'bee.git_worktree:plan',
                  'setup': 'bee.git_worktree:setup', 'cleanup': 'bee.git_worktree:cleanup', 'state': state}
        database.execute('INSERT INTO bee_placement_preparer_states VALUES (?, ?, ?)', ('attempt', record['binding_id'], json.dumps(record)))
        database.execute('INSERT INTO bee_placement_evidence VALUES (?, ?)', ('workdir_preparer.cleaned', record['binding_id']))
        database.execute('INSERT INTO bee_placement_evidence VALUES (?, ?)', ('application.log', record['binding_id']))
        database.executescript(sql('modules/placement-native/src/migrations/migrations.lua'))
        migrated = json.loads(database.execute('SELECT record_json FROM bee_placement_preparer_states').fetchone()[0])
        self.assertEqual(migrated['state'], state)
        self.assertEqual(migrated['binding_id'], 'bee.git.worktree:binding')
        for method in ['plan', 'setup', 'cleanup']:
            self.assertEqual(migrated[method], 'bee.git.worktree.binding:' + method)
        self.assertEqual(database.execute('SELECT detail FROM bee_placement_evidence WHERE kind = ?', ('workdir_preparer.cleaned',)).fetchone()[0], migrated['binding_id'])
        self.assertEqual(database.execute('SELECT detail FROM bee_placement_evidence WHERE kind = ?', ('application.log',)).fetchone()[0], record['binding_id'])
        before = database.execute('SELECT record_json FROM bee_placement_preparer_states').fetchone()[0]
        database.executescript(sql('modules/placement-native/src/migrations/migrations.lua'))
        self.assertEqual(database.execute('SELECT record_json FROM bee_placement_preparer_states').fetchone()[0], before)

    def test_placement_collision_refuses_to_overwrite_ownership(self):
        database = sqlite3.connect(':memory:')
        database.executescript('CREATE TABLE bee_placement_preparer_states (attempt_id TEXT, binding_id TEXT, record_json TEXT, PRIMARY KEY(attempt_id, binding_id)); CREATE TABLE bee_placement_evidence (kind TEXT, detail TEXT);')
        database.executemany('INSERT INTO bee_placement_preparer_states VALUES (?, ?, ?)',
                             [('attempt', 'bee.git_worktree:binding', '{"state":"old"}'),
                              ('attempt', 'bee.git.worktree:binding', '{"state":"new"}')])
        before = database.execute('SELECT * FROM bee_placement_preparer_states ORDER BY binding_id').fetchall()
        with self.assertRaises(sqlite3.IntegrityError):
            database.executescript(sql('modules/placement-native/src/migrations/migrations.lua'))
        self.assertEqual(database.execute('SELECT * FROM bee_placement_preparer_states ORDER BY binding_id').fetchall(), before)

    def test_reference_migrations_preserve_text_and_actor_identities(self):
        # Applied root-reference SQL converts M0/M5 identities. Later actor moves
        # preserve existing rows and do not extend those immutable migrations.
        migrations = json.loads((ROOT / 'build/component-inventory-migrations.json').read_text())['migrations']
        moves = {entry['from']: entry['to'] if entry['migration'] in {'M0', 'M5'} else entry['from']
                 for entry in migrations if entry['category'] == 'ids'}
        for path, tables in [
            ('modules/sync/src/migrations/migrations.lua', [('bee_sync_projections', 'value_json'), ('bee_sync_events', 'payload_json'), ('bee_sync_receipts', 'request_json')]),
            ('modules/gateway/src/migrations/migrations.lua', [('bee_gateway_surfaces', 'surface_json'), ('bee_gateway_surfaces', 'active_json'), ('bee_gateway_access_grants', 'traits_json')]),
        ]:
            database = sqlite3.connect(':memory:')
            if 'gateway' in path:
                database.execute('CREATE TABLE bee_gateway_bindings (policy_ref TEXT)')
            for table in sorted({table for table, _ in tables}):
                columns = ', '.join(column + ' TEXT' for owner, column in tables if owner == table)
                database.execute('CREATE TABLE ' + table + ' (' + columns + ')')
                database.execute('INSERT INTO ' + table + ' DEFAULT VALUES')
            original = {'references': list(moves), 'instructions': 'Call bee.git_worktree:setup later',
                        'actor': 'bee.harness.carrier:process:instance', 'opaque': json.dumps({'target': 'bee.git_worktree:binding'}),
                        'namespace': 'bee.hive.telemetry', 'service_id': 'bee.hive.telemetry',
                        'owner_ref': {'node_id': 'node', 'service_id': 'bee.hive.telemetry'}}
            for table, column in tables:
                database.execute('UPDATE ' + table + ' SET ' + column + ' = ?', (json.dumps(original),))
            database.executescript(sql(path))
            database.executescript(sql(path, "ROOT_REFERENCES_SQL"))
            for table, column in tables:
                migrated = json.loads(database.execute('SELECT ' + column + ' FROM ' + table).fetchone()[0])
                self.assertEqual(migrated['references'], list(moves.values()))
                self.assertEqual(migrated['owner_ref'], {'node_id': 'node', 'service_id': 'bee.hive.telemetry.binding'})
                for key in ['instructions', 'actor', 'opaque', 'namespace', 'service_id']:
                    self.assertEqual(migrated[key], original[key])
            database.close()

    def test_new_root_entries_and_kind_changes_are_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.wippy', prefix='layout-roots-') as temporary:
            root = Path(temporary)
            source = root / 'src'
            source.mkdir()
            (source / '_index.yaml').write_text('namespace: bee\nentries:\n- name: clock\n  kind: library.lua\n- name: workers\n  kind: registry.entry\n')
            module = root / 'modules/example/src'
            module.mkdir(parents=True)
            (module / '_index.yaml').write_text('namespace: bee.example\nentries:\n- name: definition\n  kind: ns.definition\n- name: policies\n  kind: registry.entry\n- name: helper\n  kind: library.lua\n- name: local\n  kind: contract.binding\n')
            host_component = source / 'example'
            host_component.mkdir()
            (host_component / '_index.yaml').write_text('namespace: bee.example\nentries:\n- name: executor\n  kind: exec.native\n')
            ui = root / 'modules/ui/src'
            ui.mkdir(parents=True)
            (ui / '_index.yaml').write_text('namespace: bee.ui\nentries:\n- name: appearance\n  kind: ns.requirement\n')
            errors = LAYOUT.audit(root)[0]
            self.assertTrue(any('bee.example:executor: root entry' in error for error in errors))
            for identity in ['bee:clock', 'bee:workers', 'bee.ui:appearance', 'bee.example:policies', 'bee.example:helper', 'bee.example:local']:
                self.assertTrue(any(identity + ': root entry' in error for error in errors), identity)
            self.assertFalse(any('bee.example:definition: root entry' in error for error in errors))

    def test_approver_definition_refs_must_be_live(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.wippy', prefix='layout-approvers-') as temporary:
            root = Path(temporary)
            source = root / 'src'
            source.mkdir()
            (source / '_index.yaml').write_text('namespace: bee\nentries: []\n')
            policy = source / 'security/approvals'
            policy.mkdir(parents=True)
            (policy / '_index.yaml').write_text('namespace: bee.security.approvals\nentries:\n- name: approver_policies\n  kind: registry.entry\n  meta: {type: bee.approval_policies}\n  policies:\n  - name: publication\n    approvers: [{definition_id: "bee.approvals.inbox:app"}]\n')
            self.assertTrue(any('dangling linker/import target bee.approvals.inbox:app' in error for error in LAYOUT.audit(root)[0]))

    def test_every_migration_destination_is_live(self):
        entries = {}
        for index in [*ROOT.joinpath('src').rglob('_index.yaml'), *ROOT.joinpath('modules').glob('*/src/**/_index.yaml')]:
            document = yaml.safe_load(index.read_text())
            entries.update({document['namespace'] + ':' + entry['name']: entry for entry in document.get('entries', [])})
        for destination in json.loads((ROOT / 'build/layout_identity_moves.json').read_text()).values():
            self.assertIn(destination, entries)

    def test_root_cleanup_migration_replays_and_refuses_collisions(self):
        script = sql('modules/placement-native/src/migrations/migrations.lua', 'ROOT_REFERENCES_SQL')
        database = sqlite3.connect(':memory:')
        database.executescript('CREATE TABLE bee_placement_preparer_states (attempt_id TEXT, binding_id TEXT, record_json TEXT, PRIMARY KEY(attempt_id, binding_id)); CREATE TABLE bee_placement_evidence (kind TEXT, detail TEXT); CREATE TABLE bee_placement_attempts (request_json TEXT, grants_json TEXT);')
        record = {'binding_id': 'bee.git.worktree:binding', 'state': {'token': 'bee.git.worktree:binding'}}
        # Applied root-reference SQL converts M0/M5 identities. Later actor moves
        # preserve existing rows and do not extend those immutable migrations.
        migrations = json.loads((ROOT / 'build/component-inventory-migrations.json').read_text())['migrations']
        moves = {entry['from']: entry['to'] if entry['migration'] in {'M0', 'M5'} else entry['from']
                 for entry in migrations if entry['category'] == 'ids'}
        database.execute('INSERT INTO bee_placement_preparer_states VALUES (?, ?, ?)', ('attempt', record['binding_id'], json.dumps(record)))
        database.execute('INSERT INTO bee_placement_attempts VALUES (?, ?)', (json.dumps({'references': list(moves), 'binding_ref': 'bee.driver.codex:binding'}), json.dumps({'resource': 'bee.placement.native:db'})))
        database.executescript(script)
        rows = database.execute('SELECT * FROM bee_placement_preparer_states').fetchall()
        self.assertEqual(rows[0][1], 'bee.git.worktree.binding:binding')
        self.assertEqual(json.loads(rows[0][2])['state'], record['state'])
        request, grants = database.execute('SELECT * FROM bee_placement_attempts').fetchone()
        self.assertEqual(json.loads(request)['binding_ref'], 'bee.driver.codex.binding:binding')
        self.assertEqual(json.loads(request)['references'], list(moves.values()))
        self.assertEqual(json.loads(grants)['resource'], 'bee.placement.native.env:db')
        database.executescript(script)
        self.assertEqual(database.execute('SELECT * FROM bee_placement_preparer_states').fetchall(), rows)
        database.execute('INSERT INTO bee_placement_preparer_states VALUES (?, ?, ?)', ('attempt', record['binding_id'], json.dumps(record)))
        before = database.execute('SELECT * FROM bee_placement_preparer_states ORDER BY binding_id').fetchall()
        with self.assertRaises(sqlite3.IntegrityError):
            database.executescript(script)
        self.assertEqual(database.execute('SELECT * FROM bee_placement_preparer_states ORDER BY binding_id').fetchall(), before)

    def test_scalar_resource_and_credential_references_move_without_grants(self):
        # Applied root-reference SQL converts M0/M5 identities. Later actor moves
        # preserve existing rows and do not extend those immutable migrations.
        migrations = json.loads((ROOT / 'build/component-inventory-migrations.json').read_text())['migrations']
        moves = {entry['from']: entry['to'] if entry['migration'] in {'M0', 'M5'} else entry['from']
                 for entry in migrations if entry['category'] == 'ids'}
        for module, tables in [('resources', [('bee_resource_associations', 'root_ref'), ('bee_resource_grants', 'root_ref')]), ('credentials', [('bee_credential_definitions', 'source_ref'), ('bee_credential_projections', 'materializer')])]:
            database = sqlite3.connect(':memory:')
            for table, column in tables:
                database.execute('CREATE TABLE ' + table + ' (' + column + ' TEXT, digest TEXT, authority TEXT)')
                database.executemany('INSERT INTO ' + table + ' VALUES (?, ?, ?)', [(previous, 'admitted-digest', 'admitted-authority') for previous in moves])
            script = sql('modules/' + module + '/src/migrations/migrations.lua', 'ROOT_REFERENCES_SQL')
            database.executescript(script)
            for table, column in tables:
                self.assertEqual(database.execute('SELECT * FROM ' + table).fetchall(), [(current, 'admitted-digest', 'admitted-authority') for current in moves.values()])
            database.executescript(script)

    def test_shipped_migration_bytes_are_preserved(self):
        for path in ['modules/placement-native/src/migrations/migrations.lua', 'modules/sync/src/migrations/migrations.lua', 'modules/gateway/src/migrations/migrations.lua']:
            original = subprocess.check_output(['git', 'show', SHIPPED_BASELINE + ':' + path], cwd=ROOT, text=True)
            current = (ROOT / path).read_text()
            for block in re.findall(r'\[\[(.*?)\]\]', original, re.S):
                self.assertIn(block, current, path)

    def test_main_migration_bytes_are_preserved(self):
        for module in ['placement-native', 'sync', 'gateway', 'resources', 'credentials']:
            path = 'modules/' + module + '/src/migrations/migrations.lua'
            original = subprocess.check_output(['git', 'show', 'origin/main:' + path], cwd=ROOT, text=True)
            current = (ROOT / path).read_text()
            for block in re.findall(r'\[\[(.*?)\]\]', original, re.S):
                self.assertIn(block, current, path)


if __name__ == '__main__':
    unittest.main()
