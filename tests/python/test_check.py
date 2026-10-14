"""The combined gate preserves a failed stage's exit status."""
from contextlib import redirect_stdout
import io
import unittest
from unittest.mock import patch

from tests.runner import check


class CheckTests(unittest.TestCase):
    def test_all_stages_run_serially_and_failure_is_reported_once(self):
        for status, verdict in ((0, "PASSED"), (2, "FAILED")):
            output = io.StringIO()
            with patch.object(check.subprocess, "call", return_value=status) as run, redirect_stdout(output):
                self.assertEqual(check.check(), status)
            self.assertEqual(run.call_args.args[0],
                             ["make", "--no-print-directory", "-j1", "lint", "fixture-lint", "boot-check", "test", "TESTS="])
            self.assertEqual(output.getvalue().count("CHECK "), 1)
            self.assertIn("CHECK " + verdict, output.getvalue())


if __name__ == "__main__":
    unittest.main()
