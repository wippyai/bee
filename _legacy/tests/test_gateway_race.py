"""Later samples cannot erase an earlier full-layout failure."""
from contextlib import nullcontext, redirect_stdout
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import gateway_race
from workspace import ROOT


class GatewayRaceTest(unittest.TestCase):
    def test_keeps_every_requested_sample_and_the_original_failure(self):
        fixtures = ROOT / ".wippy/fixtures"
        fixtures.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=fixtures) as temporary:
            root = Path(temporary)
            rounds = []
            cause = "container creation: context deadline exceeded\n"

            def run(index, folder, entries):
                if index == 0:
                    rounds.append(len(rounds) + 1)
                failed = index == 0 and len(rounds) == 1
                return index, entries, 1, 0.1, not failed, int(failed), cause if failed else "passed\n"

            def entries(*, resource=None):
                return [] if resource else [f"fixture:{index}" for index in range(4)]

            with patch("gateway_race.ROOT", root), patch("gateway_race.test_entries", side_effect=entries), \
                    patch("gateway_race.fixture_workspace", side_effect=lambda **kwargs: nullcontext(root)) as workspace, \
                    patch("gateway_race.run_shard", side_effect=run) as shard, \
                    patch("sys.argv", ["gateway_race.py", "--runs", "2"]), \
                    patch.dict("os.environ", {"BEE_TEST_JOBS": "4"}), redirect_stdout(StringIO()) as output:
                with self.assertRaisesRegex(SystemExit, r"failed rounds: \[1\]"):
                    gateway_race.main()

            self.assertEqual(shard.call_count, 8)
            self.assertEqual(workspace.call_count, 8)
            logs = list((root / ".wippy/gateway-race").glob("run-*/*.log"))
            self.assertEqual(len(logs), 8)
            self.assertEqual(next(log for log in logs if log.name == "round-01-shard-1.log").read_text(), cause)
            self.assertIn(cause, output.getvalue())


if __name__ == "__main__":
    unittest.main()
