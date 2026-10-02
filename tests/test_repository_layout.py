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
SPEC = importlib.util.spec_from_file_location('layout_check', ROOT / 'build/layout_check.py')
LAYOUT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAYOUT)


def sql(path):
    source = (ROOT / path).read_text()
    return re.search(r'local LAYOUT_REFERENCES_SQL = \[\[(.*?)\]\]', source, re.S)[1]


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
        moves = json.loads((ROOT / 'build/layout_identity_moves.json').read_text())
        for path, tables in [
            ('modules/sync/src/migrations/migrations.lua', [('bee_sync_projections', 'value_json'), ('bee_sync_events', 'payload_json'), ('bee_sync_receipts', 'request_json')]),
            ('modules/gateway/src/migrations/migrations.lua', [('bee_gateway_surfaces', 'surface_json'), ('bee_gateway_surfaces', 'active_json'), ('bee_gateway_access_grants', 'traits_json')]),
        ]:
            database = sqlite3.connect(':memory:')
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
            for table, column in tables:
                migrated = json.loads(database.execute('SELECT ' + column + ' FROM ' + table).fetchone()[0])
                self.assertEqual(migrated['references'], list(moves.values()))
                self.assertEqual(migrated['owner_ref'], {'node_id': 'node', 'service_id': 'bee.hive.telemetry.binding'})
                for key in ['instructions', 'actor', 'opaque', 'namespace', 'service_id']:
                    self.assertEqual(migrated[key], original[key])
            database.close()

    def test_main_migration_bytes_are_preserved(self):
        for path in ['modules/placement-native/src/migrations/migrations.lua', 'modules/sync/src/migrations/migrations.lua', 'modules/gateway/src/migrations/migrations.lua']:
            original = subprocess.check_output(['git', 'show', 'origin/main:' + path], cwd=ROOT, text=True)
            current = (ROOT / path).read_text()
            for block in re.findall(r'\[\[(.*?)\]\]', original, re.S):
                self.assertIn(block, current, path)


if __name__ == '__main__':
    unittest.main()
