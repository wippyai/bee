"""Measured budgets read a high percentile of each entry's cost distribution."""
import unittest
from tests.runner import budgets


class BudgetTests(unittest.TestCase):
    def test_costs_tighten_deadlines_without_raising_the_default_or_explicit_ceiling(self):
        self.assertEqual(budgets.entry({}, 'fast', {'fast': [.2] * 5}), 6)
        self.assertEqual(budgets.entry({}, 'slow', {'slow': [40] * 5}), 30)
        self.assertEqual(budgets.entry({'timeout': '10s'}, 'slow', {'slow': [40] * 5}), 10)
        self.assertEqual(budgets.entry({}, 'unmeasured', {}), 30)

    def test_a_single_sample_is_no_budget(self):
        self.assertEqual(budgets.entry({'timeout': '60s'}, 'once', {'once': [1.876]}), 60)
        self.assertEqual(budgets.entry({'timeout': '60s'}, 'few', {'few': [1.0] * 4}), 60)

    def test_internal_entries_read_the_95th_percentile(self):
        samples = [1.0] * 19 + [20.0]
        self.assertEqual(budgets.cost({}, samples), 1.0)
        self.assertEqual(budgets.cost({}, [1.0, 1.0, 1.0, 1.0, 3.0]), 3.0)

    def test_external_entries_need_their_own_tail_and_more_samples(self):
        meta = {'latency': 'external', 'timeout': '60s'}
        self.assertEqual(budgets.entry(meta, 'docker', {'docker': [1.9] * 9}), 60)
        samples = [1.9] * 19 + [11.5]
        self.assertEqual(budgets.cost(meta, samples), 11.5)
        self.assertEqual(budgets.entry(meta, 'docker', {'docker': samples}), 28)
        self.assertEqual(budgets.entry({'timeout': '60s'}, 'docker', {'docker': samples}), 9)

    def test_unknown_latency_class_is_refused(self):
        with self.assertRaises(ValueError):
            budgets.entry({'latency': 'slow'}, 'x', {'x': [1.0] * 10})

    def test_suite_budget_uses_only_selected_entries_and_preserves_separate_suites(self):
        documents = [{'namespace': 'fixture', 'entries': [
            {'name': 'a', 'meta': {'type': 'test', 'suite': 'bee'}},
            {'name': 'b', 'meta': {'type': 'test', 'suite': 'bee'}},
            {'name': 'c', 'meta': {'type': 'test', 'suite': 'docker'}},
            {'name': 'helper', 'meta': {'type': 'test_support', 'suite': 'bee'}},
        ]}]
        self.assertEqual(budgets.suites(documents, {'fixture:a', 'fixture:c'},
                                       {'fixture:a': [10] * 5, 'fixture:b': [1000] * 5, 'fixture:c': [2] * 5}),
                         {'bee': 50, 'docker': 34})

    def test_record_appends_passing_entries_and_keeps_the_newest_samples(self):
        report = {'results': [{'code': 0, 'failed': [], 'durations': {'fixture:a': 1.0}},
                              {'code': 1, 'failed': ['fixture:b'], 'durations': {'fixture:b': 9.0, 'fixture:c': 2.0}}]}
        recorded = budgets.record({'fixture:a': [0.5] * budgets.RETAINED}, [report])
        self.assertEqual(len(recorded['fixture:a']), budgets.RETAINED)
        self.assertEqual(recorded['fixture:a'][-1], 1.0)
        self.assertNotIn('fixture:b', recorded)
        self.assertEqual(recorded['fixture:c'], [2.0])


if __name__ == '__main__':
    unittest.main()
