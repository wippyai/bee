"""Root vocabulary has no implementation dependencies in its owner tree."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SOURCES = (ROOT / 'src', ROOT / 'drivers' / 'src')
# bee/drivers carries its value and record foundations inside its own tree;
# they are walked like the root so they too stay clear of implementation.
FOUNDATIONS = {'bee.drivers': ('bee.drivers.values', 'bee.drivers.records')}


class VocabularyTests(unittest.TestCase):
    def test_root_type_dependency_closure(self):
        entries = {}
        for path in (path for source in SOURCES for path in source.rglob('_index.yaml')):
            doc = yaml.safe_load(path.read_text())
            for entry in doc['entries']:
                entries[doc['namespace'] + ':' + entry['name']] = entry
        for owner in ('bee.harness', 'bee.drivers'):
            pending, seen = [owner + ':types'], set()
            while pending:
                identity = pending.pop()
                if identity in seen:
                    continue
                seen.add(identity)
                for target in entries[identity].get('imports', {}).values():
                    foundation = target.split(':')[0] in FOUNDATIONS.get(owner, ())
                    self.assertTrue(foundation or not target.startswith(owner + '.'), (identity, target))
                    if foundation or target.startswith(owner + ':'):
                        pending.append(target)
