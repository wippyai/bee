"""Run owner migrations against retained profile, consent and session selections."""
import hashlib
import json
from pathlib import Path
import sqlite3
import unittest
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[2]
OLD = 'bee.gov.binding:overlay_call'
NEW = 'bee.gov.traits:overlay_call'
TOOLS = {
    OLD: NEW,
    'bee.gov.binding:delivery_call': 'bee.gov.traits:delivery_call',
    'bee.node.binding:tests_call': 'bee.gov.traits:tests_call',
    'bee.hub.binding:call': 'bee.hub.traits:call',
    'bee.docs.binding:call': 'bee.docs.traits:call',
}


class ToolSelectionUpgradeTests(unittest.TestCase):
    def test_existing_selections_upgrade_without_changing_user_text_or_identity(self):
        self.assert_upgrade(include_original=True)

    def test_forward_repair_upgrades_selections_when_original_migrations_are_already_recorded(self):
        self.assert_upgrade(include_original=False)

    def assert_upgrade(self, include_original):
        db = sqlite3.connect(':memory:')
        db.row_factory = sqlite3.Row
        db.executescript('''
            CREATE TABLE bee_sync_projections(owner_id TEXT, feed TEXT, projection_key TEXT, value_json TEXT, tombstone INTEGER);
            CREATE TABLE bee_sync_feeds(owner_id TEXT, feed TEXT, head_sequence INTEGER, earliest_sequence INTEGER);
            CREATE TABLE bee_approval_grants(grant_id TEXT, domain TEXT, scope_json TEXT);
            CREATE TABLE bee_sessions(session_ref TEXT, route_json TEXT);
            CREATE TABLE bee_session_traits(session_ref TEXT, declaration_json TEXT);
            CREATE TABLE bee_session_trait_intervals(session_ref TEXT, declaration_json TEXT);
        ''')
        profile = {'name': OLD, 'bee': {'mcp': [{'tool': OLD, 'scope': {'note': OLD}}, {'tool': 'external:tool', 'scope': {}}]}, 'mcp_tools': list(TOOLS),
                   'draft': {'bee': {'mcp': [{'tool': tool, 'scope': {}} for tool in TOOLS]}, 'mcp_tools': list(TOOLS)},
                   'user_fields': {'mcp_tools': [OLD]}}
        if not include_original:
            profile['bee.mcp'] = [{'tool': OLD}]
        declaration = {'id': 'bee.gov.traits:authoring_trait', 'tools': list(TOOLS), 'prompt': OLD}
        db.execute('INSERT INTO bee_sync_projections VALUES (?,?,?,?,0)', ('owner', 'harness.profiles:workspace', 'profile', json.dumps(profile)))
        db.execute('INSERT INTO bee_sync_feeds VALUES (?,?,7,1)', ('owner', 'harness.profiles:workspace'))
        db.execute('INSERT INTO bee_approval_grants VALUES (?,?,?)', ('profile-consent', 'profile_choices', json.dumps({'parameters': {'configuration': profile}})))
        db.execute('INSERT INTO bee_approval_grants VALUES (?,?,?)', ('trait-consent', 'gateway_access', json.dumps({'parameters': {'payload': {'declarations': [declaration]}}})))
        db.execute('INSERT INTO bee_sessions VALUES (?,?)', ('session', json.dumps({'effective_profile': profile, 'profile_digest': 'before', 'note': OLD})))
        for table in ('bee_session_traits', 'bee_session_trait_intervals'):
            db.execute(f'INSERT INTO {table} VALUES (?,?)', ('session', json.dumps(declaration)))
        def encode(value):
            return json.dumps(value, sort_keys=True, separators=(',', ':'))

        def run_migration(path):
            methods = {
                'query': lambda sql, args: [dict(row) for row in db.execute(sql, args or ())],
                'execute': lambda sql, args: db.execute(sql, args or ()).rowcount,
                'decode': json.loads,
                'encode': encode,
                'digest': lambda value: hashlib.sha256(encode(value).encode()).hexdigest(),
                'sha256': lambda value: hashlib.sha256(value.encode()).hexdigest(),
            }
            command = [str(ROOT / '.wippy/build/test-migration'), str(path)]
            with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True) as process:
                for line in process.stdout:
                    request = json.loads(line)
                    result = methods[request['method']](*request['args'])
                    process.stdin.write(json.dumps(result) + '\n')
                    process.stdin.flush()
                error = process.stderr.read()
                self.assertEqual(process.wait(), 0, error)

        migrations = []
        for owner in ('harness', 'approvals', 'threads'):
            directory = ROOT / f'src/{owner}/migrations'
            entries = yaml.safe_load((directory / '_index.yaml').read_text())['entries']
            original = next(entry for entry in entries if entry['name'] == 'tool_selections')
            repair = next(entry for entry in entries if entry['name'] == 'tool_selection_paths')
            self.assertGreater(repair['meta']['timestamp'], original['meta']['timestamp'])
            self.assertEqual(repair['meta']['type'], 'migration')
            self.assertEqual(repair['meta']['target_db'], 'bee:db')
            for entry in ([original, repair] if include_original else [repair]):
                migrations.append(directory / entry['source'].removeprefix('file://'))
        feed_updates = 0
        for path in migrations:
            before = json.loads(db.execute('SELECT value_json FROM bee_sync_projections').fetchone()[0])
            run_migration(path)
            after = json.loads(db.execute('SELECT value_json FROM bee_sync_projections').fetchone()[0])
            feed_updates += before != after
        first = list(db.iterdump())
        for path in migrations:
            run_migration(path)
        self.assertEqual(list(db.iterdump()), first)
        upgraded = json.loads(db.execute('SELECT value_json FROM bee_sync_projections').fetchone()[0])
        self.assertEqual(upgraded['bee']['mcp'][0]['tool'], NEW)
        self.assertEqual(upgraded['mcp_tools'], list(TOOLS.values()))
        self.assertEqual(upgraded['draft']['mcp_tools'], list(TOOLS.values()))
        self.assertEqual([tool['tool'] for tool in upgraded['draft']['bee']['mcp']], list(TOOLS.values()))
        if not include_original:
            self.assertEqual(upgraded['bee.mcp'], profile['bee.mcp'])
        self.assertEqual(upgraded['user_fields'], profile['user_fields'])
        self.assertEqual(upgraded['name'], OLD)
        self.assertEqual(upgraded['bee']['mcp'][0]['scope']['note'], OLD)
        self.assertEqual(upgraded['bee']['mcp'][1]['tool'], 'external:tool')
        self.assertEqual(tuple(db.execute('SELECT head_sequence,earliest_sequence FROM bee_sync_feeds').fetchone()),
                         (7 + feed_updates, 8 + feed_updates))
        consent = json.loads(db.execute("SELECT scope_json FROM bee_approval_grants WHERE grant_id='profile-consent'").fetchone()[0])
        self.assertEqual(consent['parameters']['configuration'], upgraded)
        consent = json.loads(db.execute("SELECT scope_json FROM bee_approval_grants WHERE grant_id='trait-consent'").fetchone()[0])
        for table in ('bee_session_traits', 'bee_session_trait_intervals'):
            stored = json.loads(db.execute(f'SELECT declaration_json FROM {table}').fetchone()[0])
            self.assertEqual(stored, consent['parameters']['payload']['declarations'][0])
            self.assertEqual(stored['tools'], list(TOOLS.values()))
            self.assertEqual(stored['prompt'], OLD)
        route = json.loads(db.execute('SELECT route_json FROM bee_sessions').fetchone()[0])
        self.assertEqual(route['effective_profile'], upgraded)
        self.assertEqual(route['profile_digest'], hashlib.sha256(json.dumps(upgraded, sort_keys=True, separators=(',', ':')).encode()).hexdigest())
        self.assertEqual(route['note'], OLD)
