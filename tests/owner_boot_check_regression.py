# SPDX-License-Identifier: MIT
"""Exercise a supplied owner boot harness with event-driven fixture clients."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HARNESS = None
CLIENT = """#!/usr/bin/env bash
set -eu
state=$2
if [ "${3:-}" = stop ]; then
  if [ -p "$state/client-stop" ]; then printf 'stop\\n' > "$state/client-stop"; fi
  exit 0
fi
if [ -f "$state/refuse" ]; then
  echo 'bee: fixture desktop admission refused'
  if [ -f "$state/frame" ]; then echo SESSIONS; fi
  exit 1
fi
if [ -f "$state/exit-early" ]; then exit 7; fi
mkfifo "$state/client-stop"
echo SESSIONS
IFS= read -r event < "$state/client-stop"
[ "$event" = stop ]
echo 'bee: present desktop: terminal mount expired or revoked'
exit 1
"""


class OwnerBootCheck(unittest.TestCase):
    def run_harness(self, refused=False, frame=False, exit_early=False):
        scratch = ROOT / ".wippy" / "owner-boot-check-regression"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as name:
            folder = Path(name)
            source = folder / "source"
            source.mkdir()
            if refused:
                (source / "refuse").touch()
            if frame:
                (source / "frame").touch()
            if exit_early:
                (source / "exit-early").touch()
            binary = folder / "bee"
            binary.write_text(CLIENT)
            binary.chmod(0o700)
            output = folder / "output"
            result = subprocess.run(
                ["bash", str(HARNESS), str(binary), str(output), str(source)],
                env=dict(os.environ, TMPDIR=str(folder)), capture_output=True,
                text=True, timeout=30,
            )
            return result, {path.name: path.read_text() for path in output.glob("*.out")}

    def test_owner_stop_does_not_reclassify_rendered_desktop(self):
        result, captures = self.run_harness()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("result:   PASS", result.stdout)
        self.assertIn("failure:  none", result.stdout)
        self.assertIn("SESSIONS", captures["startup.out"])
        self.assertNotIn("terminal mount expired or revoked", captures["startup.out"])
        self.assertIn("terminal mount expired or revoked", captures["cleanup.out"])

    def test_startup_refusal_preserves_exact_cause(self):
        result, captures = self.run_harness(refused=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("result:   FAIL", result.stdout)
        self.assertIn("failure:  bee: fixture desktop admission refused", result.stdout)
        self.assertIn("bee: fixture desktop admission refused", captures["startup.out"])

    def test_rendered_frame_does_not_mask_startup_refusal(self):
        result, _ = self.run_harness(refused=True, frame=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("failure:  bee: fixture desktop admission refused", result.stdout)

    def test_client_exit_preserves_exit_status(self):
        result, _ = self.run_harness(exit_early=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("failure:  script client exited before desktop readiness (status 7)", result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("harness", type=Path)
    options = parser.parse_args()
    HARNESS = options.harness.resolve(strict=True)
    unittest.main(argv=[__file__])
