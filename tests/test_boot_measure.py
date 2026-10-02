"""Boot gates reject contaminated samples and compare the same machine class."""
import unittest

from boot_measure import compare, eligible, phase_timings


class BootMeasureTests(unittest.TestCase):
    def test_load_and_priority_are_part_of_sample_validity(self):
        self.assertTrue(eligible([2, 3, 4], 16, 0, 0.5))
        self.assertFalse(eligible([9, 3, 4], 16, 0, 0.5))
        self.assertFalse(eligible([2, 3, 4], 16, 3, 0.5))
        self.assertFalse(eligible([2, 3, 4], 0, 0, 0.5))

    def test_regression_uses_each_scenario_and_machine_identity(self):
        baseline = {"machine": {"cpu": "a", "cpus": 16}, "medians_ms": {"attach": 100, "warm": 500, "fresh": 1000, "upgrade": 800}}
        same = {"machine": baseline["machine"], "medians_ms": {**baseline["medians_ms"], "attach": 110, "warm": 520}}
        self.assertEqual(compare(baseline, same, 0.2), [])
        slow = {**same, "medians_ms": {**same["medians_ms"], "attach": 130, "warm": 500}}
        self.assertIn("attach", compare(baseline, slow, 0.2)[0])
        other = {**same, "machine": {"cpu": "b", "cpus": 16}}
        self.assertIn("machine", compare(baseline, other, 0.2)[0])

    def test_missing_scenarios_cannot_pass_comparison(self):
        baseline = {"machine": {}, "medians_ms": {"upgrade": 500}}
        self.assertTrue(compare(baseline, {"machine": {}, "medians_ms": {}}, 0.2))

    def test_incomplete_or_nonfinite_baseline_cannot_pass(self):
        baseline = {"machine": {}, "medians_ms": {"attach": 100}}
        self.assertTrue(compare(baseline, baseline, 0.2))
        values = dict.fromkeys(("fresh", "attach", "warm", "upgrade"), 100)
        baseline["medians_ms"] = values
        current = {**baseline, "medians_ms": {**values, "warm": float("nan")}}
        self.assertTrue(compare(baseline, current, 0.2))

    def test_phase_timings_pair_each_owner_and_preserve_unfinished_work(self):
        records = [{"pid": 1, "phase": "migration_check", "owner": "a", "stage": "begin", "time_ns": 1000000},
                   {"pid": 2, "phase": "migration_check", "owner": "b", "stage": "begin", "time_ns": 2000000},
                   {"pid": 1, "phase": "migration_check", "owner": "a", "stage": "end", "time_ns": 6000000}]
        result = phase_timings(records, 0, 10000000)
        self.assertEqual(result["durations_ms"], {"migration_check:a": [5]})
        self.assertEqual(result["pending"], ["migration_check:b"])
        self.assertEqual(result["events"][2]["exec_ms"], 6)

    def test_parallel_checks_of_one_owner_keep_actor_identity(self):
        records = [{"pid": 1, "actor": "a", "phase": "migration_check", "owner": "node", "stage": "begin", "time_ns": 1000000},
                   {"pid": 1, "actor": "b", "phase": "migration_check", "owner": "node", "stage": "begin", "time_ns": 2000000},
                   {"pid": 1, "actor": "a", "phase": "migration_check", "owner": "node", "stage": "end", "time_ns": 6000000},
                   {"pid": 1, "actor": "b", "phase": "migration_check", "owner": "node", "stage": "end", "time_ns": 8000000}]
        result = phase_timings(records, 0, 10000000)
        self.assertEqual(result["durations_ms"], {"migration_check:node": [5, 6]})
        self.assertEqual(result["pending"], [])


if __name__ == "__main__":
    unittest.main()
