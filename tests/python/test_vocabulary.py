"""Root vocabulary has no implementation dependencies in its owner tree."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class VocabularyTests(unittest.TestCase):
    def test_root_type_dependency_closure(self):
        entries = {}
        for path in (ROOT / 'src').rglob('_index.yaml'):
            doc = yaml.safe_load(path.read_text())
            for entry in doc['entries']:
                entries[doc['namespace'] + ':' + entry['name']] = entry
        for owner in ('bee.harness', 'bee.driver'):
            pending, seen = [owner + ':types'], set()
            while pending:
                identity = pending.pop()
                if identity in seen:
                    continue
                seen.add(identity)
                for target in entries[identity].get('imports', {}).values():
                    self.assertFalse(target.startswith(owner + '.'), (identity, target))
                    if target.startswith(owner + ':'):
                        pending.append(target)
