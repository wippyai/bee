"""Measured budgets preserve existing ceilings and share one suite bound."""
import unittest
from tests.runner import budgets


class BudgetTests(unittest.TestCase):
    def test_costs_tighten_deadlines_without_raising_the_default_or_explicit_ceiling(self):
        self.assertEqual(budgets.entry({}, 'fast', {'fast': .2}), 6)
        self.assertEqual(budgets.entry({}, 'slow', {'slow': 40}), 30)
        self.assertEqual(budgets.entry({'timeout': '10s'}, 'slow', {'slow': 40}), 10)
        self.assertEqual(budgets.entry({}, 'unmeasured', {}), 30)

    def test_suite_budget_uses_only_selected_entries_and_preserves_separate_suites(self):
        documents = [{'namespace': 'fixture', 'entries': [
            {'name': 'a', 'meta': {'type': 'test', 'suite': 'bee'}},
            {'name': 'b', 'meta': {'type': 'test', 'suite': 'bee'}},
            {'name': 'c', 'meta': {'type': 'test', 'suite': 'docker'}},
            {'name': 'helper', 'meta': {'type': 'test_support', 'suite': 'bee'}},
        ]}]
        self.assertEqual(budgets.suites(documents, {'fixture:a', 'fixture:c'},
                                       {'fixture:a': 10, 'fixture:b': 1000, 'fixture:c': 2}),
                         {'bee': 50, 'docker': 34})


if __name__ == '__main__':
    unittest.main()
