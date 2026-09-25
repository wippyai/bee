"""A failed Lua shard keeps its selected IDs and complete assertion output."""
from contextlib import redirect_stdout
from io import StringIO
import unittest

from unit import report_shard


class UnitRunnerReportTest(unittest.TestCase):
    def test_failed_shard_prints_ids_and_untruncated_assertion(self):
        output = "early log\n" + ("other case\n" * 100) + "Assertion failed: expected recovery state\n"
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


if __name__ == "__main__":
    unittest.main()
