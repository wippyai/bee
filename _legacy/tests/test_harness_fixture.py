"""Protocol descendants keep their pipes until the test releases them."""
import os
from pathlib import Path
import select
import subprocess
import tempfile
import unittest

from workspace import ROOT


class HarnessFixtureTest(unittest.TestCase):
    def test_orphan_holds_pipes_after_parent_exit_until_released(self):
        parent = ROOT / '.wippy/fixtures'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temporary:
            gate = Path(temporary) / 'orphan.fifo'
            os.mkfifo(gate)
            descriptor = os.open(gate, os.O_RDWR)
            try:
                child = subprocess.Popen(
                    [str(ROOT / 'tests/fixtures/harness/bin/claude')],
                    env={'PATH': '/usr/bin:/bin',
                         'BEE_FIXTURE_STREAM': str(ROOT / 'tests/fixtures/drivers/claude/stream-json-2/plain.jsonl'),
                         'BEE_FIXTURE_ORPHAN_FIFO': str(gate)},
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    self.assertEqual(child.wait(timeout=5), 0)
                    self.assertEqual(select.select([child.stderr], [], [], 0)[0], [],
                                     'the descendant must hold stderr after its parent exits')
                finally:
                    os.write(descriptor, b'release\n')
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)
                    readable = select.select([child.stderr], [], [], 5)[0]
                    self.assertTrue(readable, 'the released descendant must close its pipe')
                    self.assertEqual(child.stderr.read(), b'')
                    child.stderr.close()
            finally:
                os.close(descriptor)
