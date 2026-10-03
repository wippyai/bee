# SPDX-License-Identifier: MIT
"""Safety and failure reporting for the source-state journey harness."""
import json
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from owner_journey import Journey, JourneyDesktop, JourneyFailure, SENSITIVE, applications, safe_copy

ROOT = Path(__file__).resolve().parents[1]


class CopyTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '.wippy').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='journey-unit-', dir=ROOT / '.wippy')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()

    def test_backup_includes_committed_wal_without_modifying_source(self):
        database = self.source / 'workspace.db'
        with sqlite3.connect(database) as owner:
            owner.execute('PRAGMA journal_mode=WAL')
            owner.execute('CREATE TABLE evidence(value TEXT)')
            owner.execute("INSERT INTO evidence VALUES ('retained')")
            owner.commit()
            before = database.read_bytes()
            copied = self.root / 'copied'
            safe_copy(self.source, copied)
            self.assertFalse((copied / 'workspace.db-wal').exists())
            with sqlite3.connect(copied / 'workspace.db') as backup:
                self.assertEqual(backup.execute('SELECT value FROM evidence').fetchone(), ('retained',))
            self.assertEqual(before, database.read_bytes())

    def test_sensitive_names_and_links_are_excluded_before_open(self):
        # No credential contents are read, including in this safety regression.
        for name in ('credentials.db', 'secret', 'login-token', 'signing-key', 'auth.json'):
            (self.source / name).mkdir()
        (self.source / 'linked').symlink_to(self.source / 'credentials.db')
        (self.source / 'ordinary').write_text('retained nonsecret state')
        (self.source / 'ordinary').chmod(0o600)
        destination = self.root / 'copied'
        manifest = safe_copy(self.source, destination)
        self.assertEqual([item.name for item in destination.iterdir()], ['ordinary'])
        self.assertEqual(len(manifest['excluded']), 6)
        self.assertEqual((destination / 'ordinary').stat().st_mode & 0o777, 0o600)

    def test_overlapping_source_is_refused(self):
        with self.assertRaisesRegex(JourneyFailure, 'disjoint'):
            safe_copy(self.source, self.source / 'nested')
        self.assertFalse((self.source / 'nested').exists())

    def test_evidence_inside_source_is_refused_before_creation(self):
        with self.assertRaisesRegex(JourneyFailure, 'source must not contain'):
            Journey(Path('/usr/bin/false'), self.source, self.source / 'evidence')
        self.assertEqual(list(self.source.iterdir()), [])

    def test_corrupt_sqlite_is_not_copied_as_success(self):
        (self.source / 'workspace.db').write_text('not SQLite')
        with self.assertRaises(sqlite3.DatabaseError):
            safe_copy(self.source, self.root / 'copied')

    def test_application_evidence_preserves_owner_identity(self):
        with sqlite3.connect(self.source / 'workspace.db') as database:
            database.execute('CREATE TABLE workspace_state(workspace_id TEXT,value TEXT)')
            database.execute('INSERT INTO workspace_state VALUES (?,?)', ('workspace', json.dumps({'applications': [
                {'instance_id': 'instance', 'definition_id': 'declared:app'}]})))
        self.assertEqual(applications(self.source)[0]['instance_id'], 'instance')

    def test_sensitive_match_is_case_insensitive(self):
        for name in ('Credentials.DB', 'API_SECRET', 'accessTOKEN', 'private.KEY'):
            self.assertIsNotNone(SENSITIVE.search(name))


class ReportTests(unittest.TestCase):
    def test_session_admission_reads_the_selected_desktops_owner_store(self):
        journey = Journey.__new__(Journey)
        journey.state = Path('node-one-state')
        peer_state = Path('node-two-state')
        journey.ui = Mock(state=peer_state)
        journey.ui.text.return_value = 'SESSIONS Workspace: NEW SESSION Ready for work'
        journey.ui.screen.display = [''] * 3 + ['Claude Code'] + [''] * 6
        journey.launch = Mock()
        journey.click = Mock()
        journey.frame = Mock()
        admitted = {'session_ref': 'node-two-session'}
        with patch('owner_journey.sessions', side_effect=[[], [admitted]]) as stores:
            self.assertEqual(journey.choose_agent(), admitted)
            self.assertEqual([call.args[0] for call in stores.call_args_list], [peer_state, peer_state])

    def test_selected_hive_journey_keeps_start_and_stop(self):
        journey = Journey.__new__(Journey)
        journey.run_step = Mock()
        journey.steps = []
        journey.cleanup = Mock()
        journey.report = Mock(return_value='')
        for name in ('start', 'open_apps', 'native_stub', 'docker_session', 'restart', 'update_plan',
                     'subscriptions', 'authored_change', 'self_edit', 'hive', 'stop'):
            setattr(journey, name, Mock())
        self.assertEqual(journey.run(selected_steps={11}), 0)
        self.assertEqual([call.args[0] for call in journey.run_step.call_args_list], [1, 11, 7])

    def fixture_gateway(self, values):
        spec = importlib.util.spec_from_file_location('journey_provider', ROOT / 'tests/fixtures/owner_journey/claude.py')
        provider = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(provider)
        config = {'mcpServers': {'bee': {'url': 'http://127.0.0.1:12345/mcp',
            'headers': {'Authorization': 'Bearer ${BEE_GATEWAY_TOKEN}'}}}}
        calls = []
        responses = iter([{'result': {}}] + [{'result': {'content': [{'type': 'text', 'text': json.dumps(value)}]}}
                                         for value in values])
        def respond(request, timeout):
            calls.append(json.loads(request.data))
            response = Mock()
            response.__enter__ = Mock(return_value=io.StringIO(json.dumps(next(responses))))
            response.__exit__ = Mock(return_value=False)
            return response
        output = io.StringIO()
        with patch.dict('os.environ', {'BEE_GATEWAY_TOKEN': 'fixture-only'}), \
             patch.object(provider.urllib.request, 'urlopen', side_effect=respond), \
             patch.object(provider.time, 'sleep'), redirect_stdout(output):
            provider.main(['--mcp-config', json.dumps(config), 'JOURNEY_HIVE_APPROVAL'])
        return calls, output.getvalue()

    def test_native_fixture_stages_the_frozen_review_through_its_gateway(self):
        calls, output = self.fixture_gateway([
            {'ok': True, 'value': {'example': {'path': 'entries.json', 'entries_json': 'reviewed-example'}}},
            {'ok': True, 'value': {'revision': 1}},
            {'ok': True, 'value': {'revision': 2}},
            {'ok': True, 'value': {'digest': 'frozen-digest'}},
            {'ok': True, 'value': {'ready': True, 'diagnostics': []}}])
        self.assertEqual(calls[-1]['params']['name'], 'delivery')
        self.assertEqual(calls[-1]['params']['arguments']['snapshot_digest'], 'frozen-digest')
        self.assertEqual(calls[3]['params']['arguments']['content'], 'reviewed-example')
        self.assertIn('OWNER JOURNEY REVIEW STAGED', output)
        self.assertIn('OWNER JOURNEY STUB OUTPUT', output)
        self.assertNotIn('fixture-only', output)

    def test_native_fixture_preserves_gateway_refusal(self):
        with self.assertRaisesRegex(ValueError, 'DENIED.*fixture refusal'):
            self.fixture_gateway([{'ok': False, 'error': {'code': 'DENIED', 'message': 'fixture refusal'}}])

    def test_cycling_loading_frames_do_not_hide_a_hang(self):
        (ROOT / '.wippy').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='journey-hang-', dir=ROOT / '.wippy') as temporary:
            desktop = JourneyDesktop.__new__(JourneyDesktop)
            desktop.journey = Mock(current=None, hang_seconds=2)
            desktop.state = Path(temporary)
            desktop.process = Mock()
            desktop.process.poll.return_value = None
            frames = iter(['loading A', 'loading B'] * 50)
            desktop.pump = lambda: setattr(desktop, 'rendered', next(frames))
            desktop.text = lambda: desktop.rendered
            with patch('owner_journey.time.monotonic', side_effect=[index / 2 for index in range(100)]):
                with self.assertRaisesRegex(JourneyFailure, 'no-progress hang bound'):
                    desktop.wait_until(lambda: False, 'owner readiness')

    def test_every_dependent_step_is_failed_with_original_startup_cause(self):
        (ROOT / '.wippy').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='journey-report-', dir=ROOT / '.wippy') as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            journey = Journey(Path('/usr/bin/false'), source, root / 'evidence', hang_seconds=1)
            self.addCleanup(journey.cleanup)
            def fail():
                raise JourneyFailure('Backfill retained application alias: exact migration refusal')
            journey.run_step(1, 'startup', fail, desktop=False)
            journey.run_step(2, 'apps', lambda: self.fail('dependent action ran'))
            journey.run_step(3, 'agent', lambda: self.fail('dependent action ran'))
            report = (root / 'evidence/report.txt').read_text()
            self.assertIn('01 | FAIL', report)
            self.assertIn('02 | FAIL', report)
            self.assertEqual(journey.steps[0].cause, 'Backfill retained application alias: exact migration refusal')
            self.assertIn(journey.steps[0].cause, journey.steps[1].cause)
            self.assertEqual(journey.steps[1].cause, journey.steps[2].cause)
            self.assertTrue(all(step.frames for step in journey.steps))

class ApprovalTests(unittest.TestCase):
    def setUp(self):
        from owner_journey import Step
        self.temporary = tempfile.TemporaryDirectory(prefix='journey-approval-', dir=ROOT / '.wippy')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        source = root / 'source'
        source.mkdir()
        self.journey = Journey(Path('/usr/bin/false'), source, root / 'evidence')
        self.addCleanup(self.journey.cleanup)
        self.journey.state.mkdir()
        self.journey.current = Step(4, 'Docker')
        self.journey.current_action = 'one action'
        self.journey.baseline_approvals = set()
        self.create_store(self.journey.state)

    def create_store(self, state):
        with sqlite3.connect(state / 'approvals.db') as database:
            database.execute('CREATE TABLE bee_approval_requests(approval_id TEXT,owner_node TEXT,requester_id TEXT,request_kind TEXT,proposal_json TEXT,prompt_json TEXT,state TEXT,decision TEXT,expires_at TEXT)')

    def request(self, state, identity, decision=None, prompt=None):
        proposal = {'kind': 'operation', 'ref': 'declared:operation', 'payload': {'network': 'fixture-network'}}
        prompt = prompt or 'Allow Bee to create network fixture-network for one operation.'
        with sqlite3.connect(state / 'approvals.db') as database:
            database.execute('INSERT INTO bee_approval_requests VALUES (?,?,?,?,?,?,?,?,?)',
                             (identity, state.name, 'subject', 'permission', json.dumps(proposal),
                              json.dumps({'text': prompt}), 'decided' if decision else 'pending', decision, '2030-01-01'))

    def test_repeated_grant_is_detected_on_another_node(self):
        first = self.journey.state
        self.request(first, 'first', decision='approved')
        self.journey.observe_approvals(first)
        self.journey.observe_approvals(first)
        second = self.journey.work / 'node2'
        second.mkdir()
        self.create_store(second)
        self.request(second, 'second')
        self.journey.observe_approvals(second)
        self.assertTrue(any('already granted' in item['cause'] for item in self.journey.annoyances))

    def test_separate_decisions_for_one_action_fail(self):
        self.request(self.journey.state, 'first')
        self.request(self.journey.state, 'second')
        self.journey.observe_approvals(self.journey.state)
        self.assertTrue(any('separate decisions' in item['cause'] for item in self.journey.annoyances))
        self.assertEqual(self.journey.current.approvals, 2)

    def test_routine_action_and_missing_duration_are_reported(self):
        self.journey.current.number = 2
        self.request(self.journey.state, 'first', prompt='Allow Bee to read workspace fixture data.')
        self.journey.observe_approvals(self.journey.state)
        causes = [item['cause'] for item in self.journey.annoyances]
        self.assertTrue(any('routine' in cause for cause in causes))
        self.assertTrue(any('duration' in cause for cause in causes))
