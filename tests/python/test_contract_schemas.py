"""Published contracts describe every positional request and response."""
from pathlib import Path
import unittest
import yaml
import jsonschema

ROOT = Path(__file__).resolve().parents[2]


def registry_entries():
    for path in (ROOT / 'src').rglob('_index.yaml'):
        doc = yaml.safe_load(path.read_text())
        for entry in doc['entries']:
            yield doc['namespace'] + ':' + entry['name'], entry


class ContractSchemaTests(unittest.TestCase):
    def test_every_method_has_valid_argument_and_result_schemas(self):
        for identity, entry in registry_entries():
            if entry['kind'] != 'contract.definition':
                continue
            for method in entry['methods']:
                for direction in ('input_schemas', 'output_schemas'):
                    with self.subTest(contract=identity, method=method['name'], direction=direction):
                        self.assertTrue(method.get(direction))
                        for schema in method[direction]:
                            self.assertEqual(schema['format'], 'application/schema+json')
                            jsonschema.Draft7Validator.check_schema(schema['definition'])

    def test_unique_canonical_defaults_and_explicit_competitors(self):
        defaults = {}
        for identity, entry in registry_entries():
            if entry['kind'] != 'contract.binding':
                continue
            for binding in entry['contracts']:
                contract = binding['contract']
                if contract.startswith(('bee.driver:', 'bee.placement:')):
                    self.assertFalse(binding.get('default'), identity)
                elif contract.startswith('bee.'):
                    self.assertTrue(binding.get('default'), identity)
                if binding.get('default'):
                    self.assertNotIn(contract, defaults)
                    defaults[contract] = identity

    def test_wire_shapes_keep_structured_faults_and_driver_return_positions(self):
        entries = dict(registry_entries())

        def schema(contract, method, direction, position=0):
            method = next(m for m in entries[contract]['methods'] if m['name'] == method)
            return method[direction][position]['definition']

        output = schema('bee.approvals:contract', 'request', 'output_schemas')
        jsonschema.validate({'ok': False, 'error': {'code': 'DENIED', 'message': 'No authority'}}, output)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate({'ok': False, 'error': 'No authority'}, output)
        request = schema('bee.threads:journal', 'turn_pull', 'input_schemas')
        jsonschema.validate({'turn': 'turn', 'claim': 'fence-token'}, request)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate({'turn': 'turn', 'claim': {}}, request)
        jsonschema.validate(None, schema('bee.driver:locate_facet', 'locate', 'output_schemas'))
        jsonschema.validate('probe failed', schema('bee.driver:locate_facet', 'locate', 'output_schemas', 1))
