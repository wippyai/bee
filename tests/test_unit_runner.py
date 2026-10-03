"""Lua shard grouping, metadata discovery and complete failure reporting."""
from contextlib import nullcontext, redirect_stdout
import fcntl
from io import StringIO
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import focused_lua
from unit import docker_daemon_lock, report_shard, run_shard, split, test_entries
from workspace import ROOT


class UnitRunnerTest(unittest.TestCase):
    def test_shared_daemon_entries_run_in_one_shard_with_complete_coverage(self):
        entries = [f"fixture:{index}" for index in range(20)]
        shared = [entries[1], entries[7], entries[15]]
        groups = split(entries, shared)
        self.assertEqual(sorted(entry for group in groups for entry in group), sorted(entries))
        self.assertEqual(sum(bool(set(group) & set(shared)) for group in groups), 1)
        self.assertTrue(all(groups))

    def test_shared_daemon_group_rejects_an_unselected_entry(self):
        with self.assertRaisesRegex(AssertionError, "Shared daemon entries are not selected"):
            split([f"fixture:{index}" for index in range(8)], ["fixture:missing"])

    def test_shared_daemon_discovery_uses_declared_metadata(self):
        fixtures = ROOT / ".wippy/fixtures"
        fixtures.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=fixtures) as temporary:
            root = Path(temporary)
            tests = root / "tests/lua/arbitrary"
            tests.mkdir(parents=True)
            (tests / "_index.yaml").write_text("""namespace: fixture.unrelated
entries:
- name: first
  meta: {type: test, resources: [docker_daemon]}
- name: second
  meta: {type: test, resources: [docker_daemon]}
- name: docker_named_fixture
  meta: {type: test}
- name: support
  meta: {type: test_support, resources: [docker_daemon]}
""")
            with patch("unit.ROOT", root):
                self.assertEqual(test_entries(resource="docker_daemon"),
                                 ["fixture.unrelated:first", "fixture.unrelated:second"])
                self.assertEqual(test_entries(resource="unused"), [])

    def test_failed_shard_prints_ids_and_untruncated_assertion(self):
        output = "early log\n" + ("other case\n" * 1000) + "Assertion failed: expected recovery state\n"
        stream = StringIO()
        with redirect_stdout(stream):
            report_shard((2, ["bee.example:first_test", "bee.example:second_test"],
                          20, 4.25, False, 1, output))
        report = stream.getvalue()
        self.assertIn("bee.example:first_test", report)
        self.assertIn("bee.example:second_test", report)
        self.assertIn("exit=1", report)
        self.assertIn("early log", report)
        self.assertIn("Assertion failed: expected recovery state", report)


class DockerDaemonLockTest(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / ".wippy/fixtures"
        fixtures.mkdir(parents=True, exist_ok=True)
        temporary = TemporaryDirectory(dir=fixtures)
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.lock = self.folder / "locks/daemon.lock"
        environment = patch.dict(os.environ, {"BEE_DOCKER_DAEMON_LOCK": str(self.lock)}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        tests = self.folder / "src/tests/arbitrary"
        tests.mkdir(parents=True)
        (tests / "_index.yaml").write_text("""namespace: fixture.unrelated
entries:
- name: first
  meta: {type: test, resources: [docker_daemon]}
- name: docker_named_fixture
  meta: {type: test}
""")

    def assert_released(self):
        with self.lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)

    def test_two_processes_serialize_until_holder_releases(self):
        script = """
import fcntl
import sys
import unit
if sys.argv[1] == 'contender':
    original = fcntl.flock
    def observe(handle, operation):
        if operation == fcntl.LOCK_EX:
            try:
                original(handle, operation | fcntl.LOCK_NB)
            except BlockingIOError:
                print('contended', flush=True)
            else:
                raise RuntimeError('second process entered while first held the lock')
        return original(handle, operation)
    unit.fcntl.flock = observe
with unit.docker_daemon_lock():
    print('entered', flush=True)
    sys.stdin.readline()
    print('leaving', flush=True)
"""
        def launch(role):
            process = subprocess.Popen([sys.executable, "-u", "-c", script, role],
                                       cwd=ROOT / "tests", env=dict(os.environ),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            self.addCleanup(process.stderr.close)
            self.addCleanup(process.stdout.close)
            self.addCleanup(process.stdin.close)
            self.addCleanup(process.wait)
            self.addCleanup(lambda: process.kill() if process.poll() is None else None)
            return process

        first = launch("holder")
        self.assertIn("waiting", first.stdout.readline())
        self.assertRegex(first.stdout.readline(), r"acquired.*after [\d.]+s")
        self.assertEqual(first.stdout.readline().strip(), "entered")
        second = launch("contender")
        self.assertIn("waiting", second.stdout.readline())
        self.assertEqual(second.stdout.readline().strip(), "contended")
        first.stdin.write("release\n")
        first.stdin.flush()
        self.assertEqual(first.stdout.readline().strip(), "leaving")
        self.assertEqual(first.wait(), 0, first.stderr.read())
        self.assertRegex(second.stdout.readline(), r"acquired.*after [\d.]+s")
        self.assertEqual(second.stdout.readline().strip(), "entered")
        second.stdin.write("release\n")
        second.stdin.flush()
        self.assertEqual(second.stdout.readline().strip(), "leaving")
        self.assertEqual(second.wait(), 0, second.stderr.read())
        self.assert_released()

    def test_default_paths_and_override(self):
        for values, expected in [
            ({"XDG_RUNTIME_DIR": str(self.folder / "runtime")}, self.folder / ".cache/bee/bee-docker-daemon.lock"),
            ({}, self.folder / ".cache/bee/bee-docker-daemon.lock"),
            ({"BEE_DOCKER_DAEMON_LOCK": str(self.lock), "XDG_RUNTIME_DIR": str(self.folder / "runtime")}, self.lock),
        ]:
            with self.subTest(values=values), patch.dict(os.environ, values, clear=True), \
                    patch("unit.Path.home", return_value=self.folder), redirect_stdout(StringIO()):
                with docker_daemon_lock():
                    self.assertTrue(expected.is_file())
                    with expected.open("a") as handle:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_release_on_exception_preserves_cause(self):
        with redirect_stdout(StringIO()):
            with self.assertRaisesRegex(RuntimeError, "exact shard failure"):
                with docker_daemon_lock():
                    raise RuntimeError("exact shard failure")
        self.assert_released()

    def test_shard_locks_declared_resource_and_releases_on_runtime_failure(self):
        def fail(*args, **kwargs):
            with self.lock.open("a") as handle:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return subprocess.CompletedProcess(args[0], 1, "", "exact Docker failure")

        with patch("unit.environment", return_value={}), patch("unit.subprocess.run", side_effect=fail), \
                redirect_stdout(StringIO()):
            result = run_shard(0, self.folder, ["fixture.unrelated:first"])
        self.assertFalse(result[4])
        self.assertEqual(result[5:], (1, "exact Docker failure"))
        self.assert_released()

    def test_shard_releases_on_subprocess_exception(self):
        with patch("unit.environment", return_value={}), \
                patch("unit.subprocess.run", side_effect=OSError("exact launch failure")), \
                redirect_stdout(StringIO()):
            with self.assertRaisesRegex(OSError, "exact launch failure"):
                run_shard(0, self.folder, ["fixture.unrelated:first"])
        self.assert_released()

    def test_non_docker_selection_does_not_acquire_lock(self):
        with patch("unit.environment", return_value={}), patch("unit.docker_daemon_lock") as lock, \
                patch("unit.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "1 tests in 1 suites\n1 passed 0.1s", "")):
            result = run_shard(0, self.folder, ["fixture.unrelated:docker_named_fixture"])
        self.assertTrue(result[4])
        lock.assert_not_called()

    def test_focused_runner_uses_the_same_lock(self):
        with patch("focused_lua.fixture_workspace", return_value=nullcontext(self.folder)), \
                patch("unit.environment", return_value={}), \
                patch("unit.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "1 tests in 1 suites\n1 passed 0.1s", "")), \
                redirect_stdout(StringIO()) as output:
            focused_lua.main("fixture.unrelated", ["first"])
        self.assertIn("waiting", output.getvalue())
        self.assertRegex(output.getvalue(), r"acquired.*after [\d.]+s")
        self.assert_released()


if __name__ == "__main__":
    unittest.main()
