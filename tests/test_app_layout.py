"""Registry placement and append-only owner migration contracts."""
import json
import re
import sqlite3
import subprocess
import unittest
from pathlib import Path

from persist_migration import declared_migrations

import yaml

ROOT = Path(__file__).resolve().parents[1]


def sql_block(path, name):
    source = (ROOT / path).read_text()
    return re.search(r'local ' + name + r' = \[\[(.*?)\]\]', source, re.S)[1]


class AppLayout(unittest.TestCase):
    def test_requirement_targets_and_imports(self):
        entries = {}
        for root in [ROOT / 'src', *sorted((ROOT / 'modules').glob('*/src'))]:
            for index in root.rglob('_index.yaml'):
                document = yaml.safe_load(index.read_text())
                for entry in document.get('entries', []):
                    identity = document['namespace'] + ':' + entry['name']
                    self.assertNotIn(identity, entries, identity)
                    entries[identity] = entry
        registered = {entry['id'] for entry in json.loads(subprocess.check_output(
            [str(ROOT / '.wippy/bin/bee-wippy'), 'registry', 'list', '--json'], cwd=ROOT, text=True))}
        targets = 0
        for identity, entry in entries.items():
            if entry['kind'] == 'ns.requirement':
                for target in entry.get('targets', []):
                    self.assertTrue(target['entry'] in registered, identity + ' -> ' + target['entry'])
                    targets += 1
            for ref in entry.get('imports', {}).values():
                if ref.startswith('bee.') or ref.startswith('bee:'):
                    # The native host supplies this entry at boot.
                    if ref != 'bee.harness.host:environment':
                        self.assertTrue(ref in entries, identity + ' -> ' + ref)
        self.assertGreater(targets, 100)
        self.assertIn('bee.app:client', entries)
        for namespace in ['bee.settings', 'bee.console', 'bee.host.processes', 'bee.gov.overlays']:
            self.assertIn(namespace + '.app:app', entries)
            self.assertNotIn(namespace + ':app', entries)

    def test_workspace_migration_preserves_opaque_state_and_all_windows(self):
        database = sqlite3.connect(':memory:')
        database.executescript('CREATE TABLE workspace_application_thread_bindings (definition_id TEXT); CREATE TABLE workspace_state (value TEXT);')
        old = ['bee.settings:app', 'bee.console:app', 'bee.host.processes:app', 'bee.gov.overlays:app', 'bee.timeline:app']
        opaque = json.dumps({'definition_id': 'bee.settings:app', 'source': 'bee.application:client'})
        state = {'applications': [{'definition_id': ref, 'instance_id': str(i), 'resume_state': opaque} for i, ref in enumerate(old)]}
        database.execute('INSERT INTO workspace_state VALUES (?)', (json.dumps(state, indent=2),))
        database.executemany('INSERT INTO workspace_application_thread_bindings VALUES (?)', [(ref,) for ref in old])
        sql = sql_block('src/storage/store.lua', 'APP_CHILD_NAMES_SQL')
        database.executescript(sql)
        migrated = json.loads(database.execute('SELECT value FROM workspace_state').fetchone()[0])
        for i, app in enumerate(migrated['applications']):
            self.assertEqual(app['resume_state'], opaque)
            self.assertEqual(app['instance_id'], str(i))
            self.assertTrue(app['definition_id'].endswith('.app:app'))
        before = database.execute('SELECT value FROM workspace_state').fetchone()[0]
        database.executescript(sql)
        self.assertEqual(database.execute('SELECT value FROM workspace_state').fetchone()[0], before)

    def test_sdk_owner_data_migrations(self):
        sync = (ROOT / 'modules/sync/src/migrations/migrations.lua').read_text()
        sync_sql = re.search(r'id = 7, name = "app_sdk_references".*?sql = \[\[(.*?)\]\]', sync, re.S)[1]
        gateway_sql = sql_block('modules/gateway/src/migrations/migrations.lua', 'APP_SDK_SQL')
        for sql, tables in [(sync_sql, [('bee_sync_projections', 'value_json'), ('bee_sync_events', 'payload_json'), ('bee_sync_receipts', 'request_json')]),
                            (gateway_sql, [('bee_gateway_surfaces', 'surface_json'), ('bee_gateway_surfaces', 'active_json'), ('bee_gateway_access_grants', 'traits_json')])]:
            database = sqlite3.connect(':memory:')
            for table in sorted({table for table, _ in tables}):
                columns = ', '.join(column + ' TEXT' for owner, column in tables if owner == table)
                database.execute('CREATE TABLE ' + table + ' (' + columns + ')')
                database.execute('INSERT INTO ' + table + ' DEFAULT VALUES')
            prior = {'trait': 'bee.application:runtime', 'import': 'bee.application:client',
                     'actor': 'bee.application:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:instance',
                     'instructions': 'Use bee.application:client in this historical explanation'}
            for table, column in tables:
                database.execute('UPDATE ' + table + ' SET ' + column + ' = ?', (json.dumps(prior),))
            database.executescript(sql)
            for table, column in tables:
                value = json.loads(database.execute('SELECT ' + column + ' FROM ' + table).fetchone()[0])
                self.assertEqual(value['trait'], 'bee.app:runtime')
                self.assertEqual(value['import'], 'bee.app:client')
                self.assertEqual(value['actor'], prior['actor'])
                self.assertEqual(value['instructions'], prior['instructions'])
            database.close()

    def test_applied_sql_is_unchanged(self):
        for path in ['src/storage/store.lua', 'modules/sync/src/migrations/migrations.lua', 'modules/gateway/src/migrations/migrations.lua', 'modules/threads/src/migrations/migrations.lua']:
            original = subprocess.check_output(['git', 'show', '463ac2ea:' + path], cwd=ROOT, text=True)
            current = (ROOT / path).read_text()
            if path == 'src/storage/store.lua':
                before = declared_migrations(original)
                self.assertEqual(declared_migrations(current)[:len(before)], before, path)
                continue
            for block in re.findall(r'\[\[(.*?)\]\]', original, re.S):
                self.assertIn(block, current, path)


if __name__ == '__main__':
    unittest.main()
