"""Contracts for native output accounting and suite partitioning."""
import unittest
from unittest import mock
import json
from pathlib import Path
import tempfile

from tests.runner import run


class RunnerTests(unittest.TestCase):
    def test_fixture_preparation_finishes_before_any_timed_runner_starts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lua').mkdir()
            index = root / 'lua/_index.yaml'
            index.write_text('namespace: fixture\nentries: []\n')
            discovered = {'fixture:test': ('bee_docker', root / 'lua/body.lua', 0)}
            ready = []

            def prepare(documents, selected):
                self.assertEqual(selected, {'fixture:test'})
                ready.append(True)
                return 12.5

            def runner(*args):
                self.assertEqual(ready, [True])
                return {'shard': 1, 'counts': (1, 0, 0), 'code': 0, 'summary_found': True, 'failure': ''}

            with mock.patch.object(run, 'TESTS', root), mock.patch.object(run, 'DURATIONS', root / 'durations.json'), \
                    mock.patch.object(run, 'entries', return_value=discovered), \
                    mock.patch.object(run.docker_fixture, 'prepare', side_effect=prepare), \
                    mock.patch.object(run, 'run_shard', side_effect=runner), \
                    mock.patch.object(run.sys, 'argv', ['run.py', '--shards', '1']):
                self.assertEqual(run.main(), 0)
            report = json.loads(next((root / '.wippy/runs').iterdir()).joinpath('results.json').read_text())
            self.assertEqual(report['fixture_seconds'], 12.5)

    def test_timeline_includes_entry_overhead_and_excludes_startup_shutdown_and_repaints(self):
        timeline = run.Timeline({"a:test": ("bee", None, 0), "b:test": ("bee", None, 1)})
        timeline.line("  spinner bee (1/2) test  0%", 10)
        timeline.line("  spinner bee (1/2) test  0%", 11)
        timeline.line("    o quick case  10ms", 12)
        timeline.line("  spinner bee (2/2) test  50%", 16)
        timeline.line("    o another case  10ms", 17)
        timeline.line("  o bee (2) 2/2  19.0s", 19)
        timeline.finish(30)
        self.assertEqual(timeline.durations, {"a:test": 6, "b:test": 3})

    def test_committed_entry_clock_covers_overhead_when_terminal_output_is_buffered(self):
        values = run.entry_durations({"a:test": .01, "b:test": .02},
                                     {"a:test": .1, "b:test": 21.0}, {"a:test": 26.1})
        self.assertEqual(values, {"a:test": 26.1, "b:test": 21.0})

    def test_workspace_declares_previous_default_deadline_and_keeps_explicit_bounds(self):
        document = {"entries": [{"name": "implicit", "meta": {"type": "test"}},
                                {"name": "explicit", "meta": {"type": "test", "timeout": "60s"}},
                                {"name": "application", "meta": {"type": "app_test"}}]}
        self.assertTrue(run.declare_deadlines(document))
        self.assertEqual(document["entries"][0]["meta"]["timeout"], "30s")
        self.assertEqual(document["entries"][1]["meta"]["timeout"], "60s")
        self.assertNotIn("timeout", document["entries"][2]["meta"])
        self.assertFalse(run.declare_deadlines(document))

    def test_measured_metadata_keeps_one_budget_for_the_selected_suite(self):
        document = {"namespace": "fixture", "entries": [
            {"name": "a", "meta": {"type": "test", "suite": "bee", "timeout": "10s"}},
            {"name": "b", "meta": {"type": "test", "suite": "bee"}},
            {"name": "helper", "meta": {"type": "test_support", "suite": "bee"}}]}
        self.assertTrue(run.declare_deadlines(document, {"fixture:a": .2}, {"bee": 50}))
        first, second, helper = [item['meta'] for item in document['entries']]
        self.assertEqual((first['timeout'], second['timeout']), ('6s', '30s'))
        self.assertEqual((first['suite_timeout'], second['suite_timeout']), ('50s', '50s'))
        self.assertNotIn('timeout', helper)
        self.assertNotIn('suite_timeout', helper)

    def test_hygiene_wrap_preserves_body_security_method_and_event_identity(self):
        entry = {"name": "example", "kind": "function.lua", "source": "file://body.lua", "method": "native",
                 "meta": {"type": "test", "timeout": "7s"}, "modules": ["sql"],
                 "imports": {"test": "wippy.test:test"}, "security": {"policies": ["scope"]}}
        document = {"namespace": "fixture", "entries": [entry]}
        self.assertTrue(run.wrap_suites(document, "file://wrapper.lua"))
        body = document["entries"][1]
        self.assertEqual((body["source"], body["method"], body["security"], body["imports"]),
                         ("file://body.lua", "native", {"policies": ["scope"]}, {"test": "wippy.test:test"}))
        self.assertEqual(entry["meta"], {"type": "test", "timeout": "7s", "hygiene_body": "fixture:example__body"})
        self.assertEqual(body["meta"]["type"], "test_support")
        self.assertNotIn("security", entry)
        self.assertEqual(len(document["entries"]), 2)

    def test_duration_balance_keeps_every_suite_exactly_once(self):
        selected = {name: ("bee", None, 0) for name in ("slow", "medium", "fast", "unknown")}
        groups = run.balance(selected, {"slow": 10, "medium": 6, "fast": 4}, 2)
        self.assertEqual(groups, [["slow", "unknown"], ["medium", "fast"]])
        self.assertEqual(sorted(name for group in groups for name in group), sorted(selected))
        self.assertEqual(len(run.balance(selected, {}, 99)), len(selected))

    def test_ci_selection_uses_the_same_complete_plan_and_global_numbers(self):
        selected = run.entries()
        groups = run.balance(selected, json.loads(run.DURATIONS.read_text()), 8)
        self.assertEqual(len(groups), 8)
        collected = []
        for shard in range(1, 9):
            active = run.select_shards(groups, shard)
            self.assertEqual(active, [(shard, groups[shard - 1])])
            collected.extend(active[0][1])
        self.assertEqual(sorted(collected), sorted(selected))
        self.assertEqual(len(collected), len(set(collected)))
        self.assertEqual(run.select_shards(groups, None), list(enumerate(groups, 1)))
        for invalid in (0, 9, -1):
            with self.assertRaises(ValueError):
                run.select_shards(groups, invalid)

    def test_native_summary_accepts_success_and_failure_formats(self):
        for output, expected in (("  10 tests  1.6s", ("10", "", "", "1.6s")),
                                 ("  11 tests  601ms", ("11", "", "", "601ms")),
                                 ("  1 tests  <1ms", ("1", "", "", "<1ms")),
                                 ("  2728 passed  37 failed  4312.1s", ("2728", "37", "", "4312.1s")),
                                 ("  10 passed  1 failed  2 skipped  4.0s", ("10", "1", "2", "4.0s"))):
            self.assertEqual(run.SUMMARY.findall(output), [expected])
        self.assertEqual(run.SUMMARY.findall("No tests found"), [])

    def test_docker_entries_share_one_runtime_without_losing_other_suites(self):
        selected = {"docker:a": ("bee_docker", None, 0), "docker:b": ("bee_docker", None, 0),
                    "plain:a": ("bee", None, 0), "plain:b": ("bee", None, 0)}
        groups = run.balance(selected, {}, 3)
        self.assertEqual(groups, [["docker:a", "docker:b"], ["plain:a"], ["plain:b"]])

    def test_measure_distinguishes_same_short_name_and_ignores_suite_total(self):
        selected = {"a:shared_test": ("bee", None, 2), "b:shared_test": ("bee", None, 1)}
        output = ("\x1b[2K\r  spinner bee (1/2) shared_test  0%\n"
                  "    o first case  300ms\n"
                  "\x1b[2K\r  spinner bee (1/2) shared_test  0%\n"
                  "    o another case  2.0s\n"
                  "\x1b[2K\r  spinner bee (2/2) shared_test  50%\n"
                  "    x last case  400ms\n"
                  "  x bee (3) 1 failed  99.0s\n")
        _, durations, cases = run.measure(output, selected)
        self.assertEqual(durations, {"b:shared_test": 2.3, "a:shared_test": .4})
        self.assertEqual(len(cases), 3)

    def test_partial_log_filters_duplicate_short_names_before_measuring(self):
        selected = {"a:shared_test": ("bee", None, 0), "b:shared_test": ("bee", None, 0)}
        output = ("  Filter: b:shared_test\n  spinner bee (1/1) shared_test  100%\n"
                  "    o selected case  20ms\n")
        self.assertEqual(run.measure(output, selected)[1], {"b:shared_test": .02})

    def test_native_substring_collisions_stay_in_one_shard(self):
        selected = {name: ("bee", None, 0) for name in ("a:application_test", "a:application_tests_test", "b:other_test")}
        groups = run.balance(selected, {}, 3)
        self.assertEqual(len(groups), 2)
        for group in groups:
            native_selection = {name for name in selected if any(pattern in name for pattern in group)}
            self.assertEqual(native_selection, set(group))


if __name__ == "__main__":
    unittest.main()
