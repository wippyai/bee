"""OS ownership includes adopted descendants and excludes the inspector itself."""
import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile
import os
import queue
import threading

spec = importlib.util.spec_from_file_location('process_guard', Path(__file__).parent / 'lua/hygiene/process_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ProcessGuardTests(unittest.TestCase):
    def test_descendants_include_orphans_adopted_by_the_shard(self):
        rows = {2: {'parent': 1, 'start': '10', 'name': 'wippy'},
                3: {'parent': 2, 'start': '11', 'name': 'child'},
                4: {'parent': 1, 'start': '12', 'name': 'orphan'},
                5: {'parent': 99, 'start': '13', 'name': 'other-shard'}}
        self.assertEqual(set(guard.descendants(rows, 1)), {'os:2:10', 'os:3:11', 'os:4:12'})
        self.assertEqual(set(guard.descendants(rows, 1, [2])), {'os:4:12'})

    def test_guard_reports_and_joins_a_real_adopted_orphan(self):
        root = Path(__file__).parent / '.wippy'
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root, prefix='guard-contract-') as directory:
            Path(directory, '.wippy').mkdir()
            program = "import os,signal\nif os.fork() == 0: signal.pause()\nelse: os._exit(0)"
            result = subprocess.run([sys.executable, str(Path(guard.__file__).resolve()), 'run', sys.executable, '-c', program],
                                    cwd=directory, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('Shard OS process leaks:', result.stdout)

    def test_guard_preserves_the_command_failure_status(self):
        root = Path(__file__).parent / '.wippy'
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root, prefix='guard-contract-') as directory:
            Path(directory, '.wippy').mkdir()
            result = subprocess.run([sys.executable, str(Path(guard.__file__).resolve()), 'run', sys.executable, '-c', 'raise SystemExit(7)'],
                                    cwd=directory, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_snapshot_finds_children_created_by_another_thread(self):
        children = queue.Queue()
        release = threading.Event()
        def spawn():
            child = subprocess.Popen([sys.executable, '-c', 'import signal; signal.pause()'])
            children.put(child)
            release.wait()
        worker = threading.Thread(target=spawn)
        worker.start()
        child = children.get(timeout=5)
        try:
            observed = guard.snapshot(os.getpid())
            self.assertTrue(any(identity.split(':')[1] == str(child.pid) for identity in observed), observed)
            self.assertFalse(any(identity.split(':')[1] == str(child.pid)
                                 for identity in guard.snapshot(os.getpid(), [child.pid])))
        finally:
            child.terminate()
            child.wait(timeout=5)
            release.set()
            worker.join(timeout=5)
        self.assertFalse(worker.is_alive())

    def test_process_identity_distinguishes_pid_reuse(self):
        rows = {2: {'parent': 1, 'start': '10', 'name': 'child'}}
        before = guard.descendants(rows, 1)
        rows[2]['start'] = '20'
        self.assertNotEqual(before, guard.descendants(rows, 1))


if __name__ == '__main__':
    unittest.main()
