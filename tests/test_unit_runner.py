"""Lua shard grouping, metadata discovery and complete failure reporting."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from unit import report_shard, split, test_entries
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


if __name__ == "__main__":
    unittest.main()
