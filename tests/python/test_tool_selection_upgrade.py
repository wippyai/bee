"""Run owner migrations against retained profile, consent and session selections."""
import hashlib
import json
from pathlib import Path
import sqlite3
import unittest
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
OLD = 'bee.gov.binding:overlay_call'
NEW = 'bee.gov.traits:overlay_call'


class ToolSelectionUpgradeTests(unittest.TestCase):
    def test_existing_selections_upgrade_without_changing_user_text_or_identity(self):
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
        profile = {'name': OLD, 'bee': {'mcp': [{'tool': OLD, 'scope': {'note': OLD}}, {'tool': 'external:tool', 'scope': {}}]}, 'mcp_tools': [OLD]}
        declaration = {'id': 'bee.gov.traits:authoring_trait', 'tools': [OLD], 'prompt': OLD}
        db.execute('INSERT INTO bee_sync_projections VALUES (?,?,?,?,0)', ('owner', 'harness.profiles:workspace', 'profile', json.dumps(profile)))
        db.execute('INSERT INTO bee_sync_feeds VALUES (?,?,7,1)', ('owner', 'harness.profiles:workspace'))
        db.execute('INSERT INTO bee_approval_grants VALUES (?,?,?)', ('profile-consent', 'profile_choices', json.dumps({'parameters': {'configuration': profile}})))
        db.execute('INSERT INTO bee_approval_grants VALUES (?,?,?)', ('trait-consent', 'gateway_access', json.dumps({'parameters': {'payload': {'declarations': [declaration]}}})))
        db.execute('INSERT INTO bee_sessions VALUES (?,?)', ('session', json.dumps({'effective_profile': profile, 'profile_digest': 'before', 'note': OLD})))
        for table in ('bee_session_traits', 'bee_session_trait_intervals'):
            db.execute(f'INSERT INTO {table} VALUES (?,?)', ('session', json.dumps(declaration)))
        lua = LuaRuntime(unpack_returned_tuples=True)

        def encode(value):
            def unpack(item):
                if hasattr(item, 'items'):
                    pairs = dict(item.items())
                    if pairs and all(isinstance(key, int) for key in pairs):
                        return [unpack(pairs[k]) for k in sorted(pairs)]
                    return {key: unpack(v) for key, v in pairs.items()}
                return item
            return json.dumps(unpack(value), sort_keys=True, separators=(',', ':'))

        def arguments(args):
            return tuple(args.values()) if args is not None else ()

        database = lua.table_from({
            'query': lambda _, sql, args=None: lua.table_from([lua.table_from(dict(row)) for row in db.execute(sql, arguments(args))]),
            'execute': lambda _, sql, args=None: db.execute(sql, arguments(args)).rowcount,
        })
        modules = lua.table_from({
            'json': lua.table_from({'decode': lambda value: lua.table_from(json.loads(value), recursive=True)}),
            'canonical': lua.table_from({'encode': encode, 'digest': lambda value: hashlib.sha256(encode(value).encode()).hexdigest()}),
            'hash': lua.table_from({'sha256': lambda value: hashlib.sha256(value.encode()).hexdigest()}),
        })
        lua.globals().modules = modules
        lua.globals().db = database
        lua.execute('''
            function migration(_, body) body() end
            function database(_, body) body() end
            function up(body) body(db) end
            modules.migration = {define = function(body) return body end}
            function require(name) return assert(modules[name], name) end
        ''')
        migrations = [ROOT / f'src/{owner}/migrations/tool_selections.lua' for owner in ('harness', 'approvals', 'threads')]
        for path in migrations:
            lua.execute(path.read_text())()
        first = list(db.iterdump())
        for path in migrations:
            lua.execute(path.read_text())()
        self.assertEqual(list(db.iterdump()), first)
        upgraded = json.loads(db.execute('SELECT value_json FROM bee_sync_projections').fetchone()[0])
        self.assertEqual(upgraded['bee']['mcp'][0]['tool'], NEW)
        self.assertEqual(upgraded['mcp_tools'], [NEW])
        self.assertEqual(upgraded['name'], OLD)
        self.assertEqual(upgraded['bee']['mcp'][0]['scope']['note'], OLD)
        self.assertEqual(upgraded['bee']['mcp'][1]['tool'], 'external:tool')
        self.assertEqual(tuple(db.execute('SELECT head_sequence,earliest_sequence FROM bee_sync_feeds').fetchone()), (8, 9))
        consent = json.loads(db.execute("SELECT scope_json FROM bee_approval_grants WHERE grant_id='profile-consent'").fetchone()[0])
        self.assertEqual(consent['parameters']['configuration'], upgraded)
        consent = json.loads(db.execute("SELECT scope_json FROM bee_approval_grants WHERE grant_id='trait-consent'").fetchone()[0])
        for table in ('bee_session_traits', 'bee_session_trait_intervals'):
            stored = json.loads(db.execute(f'SELECT declaration_json FROM {table}').fetchone()[0])
            self.assertEqual(stored, consent['parameters']['payload']['declarations'][0])
            self.assertEqual(stored['tools'], [NEW])
            self.assertEqual(stored['prompt'], OLD)
        route = json.loads(db.execute('SELECT route_json FROM bee_sessions').fetchone()[0])
        self.assertEqual(route['effective_profile'], upgraded)
        self.assertEqual(route['profile_digest'], hashlib.sha256(json.dumps(upgraded, sort_keys=True, separators=(',', ':')).encode()).hexdigest())
        self.assertEqual(route['note'], OLD)
