"""Trait tools have bounded public metadata and resolve their named scopes."""
import json
import unittest
from tests.python.test_contract_schemas import registry_entries
import jsonschema


class TraitToolTests(unittest.TestCase):
    def test_tools_resolve_with_schemas_and_host_scopes(self):
        entries = dict(registry_entries())
        for namespace in ('bee.gov.traits', 'bee.hub.traits', 'bee.docs.traits'):
            for identity, entry in entries.items():
                if not identity.startswith(namespace + ':'):
                    continue
                if entry.get('meta', {}).get('type') == 'agent.trait':
                    for ref in entry.get('tools', []):
                        self.assertEqual(entries[ref]['meta']['type'], 'tool', ref)
                        self.assertTrue(ref.startswith(namespace + ':'), ref)
                if entry.get('meta', {}).get('type') != 'tool':
                    continue
                meta = entry['meta']
                for field in ('input_schema', 'output_schema'):
                    jsonschema.Draft7Validator.check_schema(json.loads(meta[field]))
                self.assertTrue(meta['mcp']['required_scopes'], identity)
                for ref in meta['mcp']['required_scopes']:
                    self.assertIn(entries[ref]['kind'], ('security.policy', 'security.policy.expr'))
                self.assertIn(identity, str(entries[meta['mcp']['required_scopes'][0]]['policy']))
        for ref in ('bee.gov.binding:overlay_call', 'bee.hub.binding:call', 'bee.docs.binding:call'):
            self.assertNotEqual(entries[ref].get('meta', {}).get('type'), 'tool')
