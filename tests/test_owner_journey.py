# SPDX-License-Identifier: MIT
"""Safety and failure reporting for the source-state journey harness."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
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

    def test_copy_preserves_cache_deployments_and_other_state(self):
        retained = ('cache/bee/credentials-0.1.0-dev.wapp',
                    'deployments/current/.wippy/vendor/bee/credentials-0.1.0-dev.wapp',
                    'deployments/current/wippy.lock', 'cache/resolution.lock',
                    'node.identity', 'credits.txt')
        excluded = ('credentials.db', 'credentials.db.client', 'Credentials.DB-wal',
                    'API_SECRET', 'accessTOKEN', 'private.KEY', 'lock', '.lock',
                    'owner.lock', 'node.identity.lock', '.read.lock',
                    'owner.pid', 'owner.log', 'workspace.db-wal',
                    'workspace.db-shm', 'workspace.db-journal', 'cache/secret-folder')
        for name in retained:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('public state')
        for name in excluded:
            (self.source / name).mkdir()
        destination = self.root / 'copied'
        manifest = safe_copy(self.source, destination)
        for name in retained:
            self.assertEqual((destination / name).read_text(), 'public state')
        for name in excluded:
            self.assertFalse((destination / name).exists(), name)
        self.assertEqual(set(manifest['copied']), set(retained))
        self.assertEqual({item['path'] for item in manifest['excluded']}, set(excluded))

    def test_backup_covers_all_state_database_names(self):
        for name in ('workspace.db.client', 'workspace.db.catalog', 'catalog.sqlite'):
            with sqlite3.connect(self.source / name) as owner:
                owner.execute('PRAGMA journal_mode=WAL')
                owner.execute('CREATE TABLE evidence(value TEXT)')
                owner.execute("INSERT INTO evidence VALUES ('retained')")
                owner.commit()
                destination = self.root / name
                safe_copy(self.source, destination)
                self.assertFalse((destination / (name + '-wal')).exists())
                with sqlite3.connect(destination / name) as backup:
                    self.assertEqual(backup.execute('SELECT value FROM evidence').fetchone(), ('retained',))

    def test_journey_keeps_copied_cache_and_deployments_at_startup(self):
        for name in ('cache/bee/credentials-0.1.0-dev.wapp', 'deployments/current/wippy.lock'):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('public state')
        journey = Journey(Path('/usr/bin/false'), self.source, self.root / 'evidence')
        self.addCleanup(journey.cleanup)
        def attach():
            self.assertTrue((journey.state / 'cache/bee/credentials-0.1.0-dev.wapp').is_file())
            self.assertTrue((journey.state / 'deployments/current/wippy.lock').is_file())
            (journey.state / 'credentials.db').touch()
        with patch.object(journey, 'attach', side_effect=attach), patch.object(journey, 'frame'):
            journey.start()

    def test_sensitive_names_are_excluded_before_open_and_links_are_not_followed(self):
        # No credential contents are read, including in this safety regression.
        for name in ('credentials.db', 'secret', 'login-token', 'signing-key'):
            (self.source / name).mkdir()
        (self.source / 'linked').symlink_to(self.source / 'credentials.db')
        (self.source / 'ordinary').write_text('retained nonsecret state')
        (self.source / 'ordinary').chmod(0o600)
        destination = self.root / 'copied'
        manifest = safe_copy(self.source, destination)
        self.assertEqual({item.name for item in destination.iterdir()}, {'ordinary', 'linked'})
        self.assertEqual(len(manifest['excluded']), 4)
        self.assertTrue((destination / 'linked').is_symlink())
        self.assertEqual((destination / 'linked').readlink(), self.source / 'credentials.db')
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

    def test_hive_decision_controls_the_peer_workspace_from_the_primary_display(self):
        journey = Journey.__new__(Journey)
        journey.ui = Mock()
        journey.ui.text.return_value = 'Control this workspace here? Duration: until you leave Alt+Q leave'
        journey.record_person_prompt = Mock()
        journey.control_hive_workspace()
        self.assertEqual([call.args[0] for call in journey.ui.key.call_args_list],
                         [b"\x1bq", b"c", b"\t\r"])
        self.assertEqual([call.args[0] for call in journey.ui.wait.call_args_list],
                         ['HIVE MANAGER', 'Control this workspace here?', 'Control'])
        journey.record_person_prompt.assert_called_once_with('Control node 2 workspace', journey.ui.text())

    def test_remote_inbox_click_uses_the_peer_bar_below_the_local_bar(self):
        journey = Journey.__new__(Journey)
        journey.ui = Mock()
        journey.ui.screen.display = [' BEE Needs you 0', 'REMOTE Control', ' BEE Needs you 1']
        journey.frame = Mock()
        journey.open_remote_inbox()
        self.assertEqual([call.args for call in journey.ui.mouse.call_args_list],
                         [(0, 6, 3), (0, 6, 3, True)])
        journey.ui.wait.assert_called_once_with('NEEDS YOU')

    def test_remote_review_selects_a_request_and_uses_allow_once(self):
        journey = Journey.__new__(Journey)
        journey.ui = Mock()
        journey.ui.text.return_value = 'Allow once · exact reviewed scope'
        journey.record_person_prompt = Mock()
        journey.frame = Mock()
        journey.allow_remote_review()
        self.assertEqual([call.args[0] for call in journey.ui.key.call_args_list], [b"k\r", b"a"])
        journey.ui.wait.assert_called_once_with('Allow once')

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
        calls = []
        responses = iter([{'result': {}}] + [{'result': {'content': [{'type': 'text', 'text': json.dumps(value)}]}}
                                         for value in values])
        class Gateway(BaseHTTPRequestHandler):
            def do_POST(self):
                calls.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.server.authorizations.append(self.headers.get('Authorization'))
                body = json.dumps(next(responses)).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory(prefix='journey-gateway-', dir=ROOT / '.wippy') as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            journey = Journey(Path('/usr/bin/false'), source, root / 'evidence')
            self.addCleanup(journey.cleanup)
            with ThreadingHTTPServer(('127.0.0.1', 0), Gateway) as server:
                server.authorizations = []
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                try:
                    config = {'mcpServers': {'bee': {'url': f'http://127.0.0.1:{server.server_port}/mcp',
                        'headers': {'Authorization': 'Bearer ${BEE_GATEWAY_TOKEN}'}}}}
                    result = subprocess.run([str(journey.stub_bin / 'claude'), '--mcp-config', json.dumps(config),
                                             'JOURNEY_HIVE_APPROVAL'], capture_output=True, text=True,
                                            env={**journey.environment, 'BEE_GATEWAY_TOKEN': 'fixture-only'}, timeout=10)
                finally:
                    server.shutdown()
                    thread.join()
            self.assertTrue(all(value == 'Bearer fixture-only' for value in server.authorizations))
        return calls, result

    def test_native_fixture_stages_the_frozen_review_through_its_gateway(self):
        calls, result = self.fixture_gateway([
            {'ok': True, 'value': {'example': {'path': 'entries.json', 'entries_json': 'reviewed-example'}}},
            {'ok': True, 'value': {'revision': 1}},
            {'ok': True, 'value': {'revision': 2}},
            {'ok': True, 'value': {'digest': 'frozen-digest'}},
            {'ok': True, 'value': {'ready': True, 'diagnostics': []}}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 6)
        self.assertEqual(calls[-1]['params']['name'], 'delivery')
        self.assertEqual(calls[-1]['params']['arguments']['snapshot_digest'], 'frozen-digest')
        self.assertEqual(calls[3]['params']['arguments']['content'], 'reviewed-example')
        self.assertIn('OWNER JOURNEY REVIEW STAGED', result.stdout)
        self.assertIn('OWNER JOURNEY STUB OUTPUT', result.stdout)
        self.assertNotIn('fixture-only', result.stdout + result.stderr)

    def test_native_fixture_preserves_gateway_refusal(self):
        for failure in ({'ok': False, 'error': {'code': 'DENIED', 'message': 'fixture refusal'}},
                        {'ok': False, 'code': 'DENIED', 'message': 'fixture refusal'}):
            calls, result = self.fixture_gateway([failure])
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stderr, 'DENIED.*fixture refusal')
            self.assertNotIn('OWNER JOURNEY STUB OUTPUT', result.stdout)
            self.assertNotIn('fixture-only', result.stdout + result.stderr)

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

    def test_approval_driver_opens_the_request_before_allowing_once(self):
        self.request(self.journey.state, 'first')
        state = {'selected': False, 'detail': False, 'approved': False}
        desktop = Mock(state=self.journey.state)
        desktop.text.side_effect = lambda: 'State: approved' if state['approved'] else ('Subject: Bee\nScope: fixture network\nDuration: once\nA Allow once' if state['detail'] else '1 pending · A approve')
        self.journey.ui = desktop
        self.journey.frame = Mock()
        self.journey.record_person_prompt = Mock()
        def click(label):
            self.assertEqual(label, 'pending   ')
            state['selected'] = True
        self.journey.click = click
        def wait(label):
            self.assertNotEqual(label, 'Approve this request?', 'Allow once already commits the decision')
            if label == 'Allow once':
                self.assertTrue(state['selected'])
                state['detail'] = True
        desktop.wait.side_effect = wait
        def key(value):
            self.assertTrue(state['selected'], 'select the request before opening or deciding it')
            if value == b'a':
                self.assertTrue(state['detail'], 'wait for the rendered decision before sending Allow once')
                with sqlite3.connect(self.journey.state / 'approvals.db') as database:
                    database.execute("UPDATE bee_approval_requests SET state='decided',decision='approved' WHERE approval_id='first'")
                state['approved'] = True
            else:
                self.assertEqual(value, b'\r')
        desktop.key.side_effect = key
        desktop.wait_until.side_effect = lambda condition, description: self.assertTrue(condition(), description)
        self.journey.approve('first')
        self.assertTrue(state['detail'])
        self.journey.record_person_prompt.assert_called_once()
        self.assertIn('Scope: fixture network', self.journey.record_person_prompt.call_args.args[1])


class FixtureTests(unittest.TestCase):
    def test_deterministic_provider_is_a_linux_runtime_artifact(self):
        with tempfile.TemporaryDirectory(prefix='journey-fixture-', dir=ROOT / '.wippy') as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            journey = Journey(Path('/usr/bin/false'), source, root / 'evidence')
            self.addCleanup(journey.cleanup)
            executable = journey.stub_bin / 'claude'
            with executable.open('rb') as binary:
                self.assertEqual(binary.read(4), b'\x7fELF')
            self.assertEqual(executable.stat().st_mode & 0o005, 0o005, 'the non-root container user must read and execute the artifact')
            self.assertFalse((journey.fixture_home / 'go').exists(), 'the build toolchain must stay outside the provider home')
            result = subprocess.run([str(executable), '--version'], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), '2.1.265')
