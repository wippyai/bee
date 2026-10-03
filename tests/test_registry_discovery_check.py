# SPDX-License-Identifier: MIT
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'build'))
import registry_discovery_check as check


class DiscoveryCheckTest(unittest.TestCase):
    def test_rejects_name_decisions_and_transformations(self):
        sources = [
            'if entry.id:sub(1, #prefix) == prefix then return true end',
            'if ref:match("^vendor%.drivers:") then return true end',
            'if comp:match("^vendor/") then return true end',
            'if entry.id:find("bee.", 1, true) then return true end',
            'local ref = namespace .. ":" .. "configure"',
            'local ref = binding_ref:gsub(":", ".")',
            'local ref = binding_ref:match("^(.*)%.binding:binding$")',
            'local rows = pinned:find({[".ns"] = namespace})',
            'local rows = registry.find({[".name"] = "binding"})',
            'if candidate:match("^app%.") then return true end',
            'if actor:sub(1, #prefix) == prefix then return true end',
            'if choice:match("^provider:") then return true end',
            'if choice:sub(1, #sibling_prefix) == sibling_prefix then return true end',
            'if entry.id == "bee.hub.operations:" .. digest then return true end',
            'local selected = scope .. ":" .. APPLICATION_NAME',
        ]
        for source in sources:
            with self.subTest(source=source):
                self.assertTrue(check.findings(source))

    def test_rejects_registry_permission_patterns_in_policy_strings(self):
        self.assertTrue(check.findings("""local policy = '(action == "funcs.call" && resource matches "^vendor[.]binding:[A-Za-z]+$")' """))

    def test_accepts_metadata_and_exact_references(self):
        for source in [
            'registry.find({[".kind"] = "contract.binding", ["meta.type"] = "harness.driver"})',
            'local entry = pinned:get(requirement.target)',
            'local entry = registry.get("bee.env:workspace_db")',
            'if id:match("^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$") then return id end',
            '-- if id:match("^bee%.") then return true end',
            'local example = [[ id:match("^bee%.") ]]',
            '''local example = 'id:match("^bee%.")' ''',
            '''local example = 'entry.id == "vendor:receipt" .. digest' ''',
            '''local example = 'namespace .. ":" .. target' ''',
        ]:
            with self.subTest(source=source):
                self.assertFalse(check.findings(source))

    def test_allowlist_is_exact_and_requires_explanation(self):
        source = 'if id:match("^old%.owner:") then return true end'
        finding = check.findings(source)[0]
        reviewed = [{'path': 'src/owner.lua', 'expression': finding['expression'],
                     'count': 1, 'reason': 'M0 immutable persisted identity decoder'}]
        self.assertEqual(check.unreviewed('src/owner.lua', check.findings(source), reviewed), [])
        self.assertTrue(check.unreviewed('src/other.lua', check.findings(source), reviewed))
        self.assertTrue(check.unreviewed('src/owner.lua', check.findings(source.replace('old', 'new')), reviewed))
        with self.assertRaises(ValueError):
            check.unreviewed('src/owner.lua', check.findings(source), [{'path': 'src/owner.lua', 'expression': finding['expression']}])

    def test_coordinated_lane_files_are_in_production_scope(self):
        root = Path(__file__).resolve().parents[1]
        paths = {str(path.relative_to(root)) for path in check.production_paths(root)}
        self.assertIn('modules/sessions/src/executor/driver_route.lua', paths)
        self.assertIn('modules/executor-external/src/service/turn.lua', paths)

    def test_executor_startup_event_key_review_is_exact(self):
        import json
        import tempfile
        root = Path(__file__).resolve().parents[1]
        path = 'modules/executor-external/src/binding/run_turn.lua'
        expression = 'attempt_id .. ":" .. state'
        reviewed = [item for item in json.loads((root / 'build/registry_discovery_allowlist.json').read_text())
                    if item['path'] == path and item['expression'] == expression]
        with tempfile.TemporaryDirectory(dir=root / '.wippy', prefix='discovery-startup-event-') as folder:
            tree = Path(folder)
            source = tree / path
            source.parent.mkdir(parents=True)
            (tree / 'build').mkdir()
            (tree / 'build/registry_discovery_allowlist.json').write_text(json.dumps(reviewed))
            source.write_text('local event_key = "placement:" .. ' + expression)
            self.assertEqual(check.audit(tree), [])
            source.write_text('local ref = namespace .. ":" .. state')
            self.assertTrue(any('registry discovery by name' in item for item in check.audit(tree)))

    def test_requirement_targets_are_checked_without_a_brand_prefix(self):
        import tempfile
        import layout_check
        import yaml
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=root / '.wippy', prefix='discovery-layout-') as folder:
            tree = Path(folder)
            index = tree / 'src' / 'wiring' / '_index.yaml'
            index.parent.mkdir(parents=True)
            index.write_text(yaml.safe_dump({'namespace': 'bee.wiring', 'entries': [
                {'name': 'selection', 'kind': 'ns.requirement', 'targets': [
                    {'entry': 'vendor.plugin:missing', 'path': '.config'}]}]}))
            errors, _, _, _, dangling = layout_check.audit(tree)
            self.assertEqual(dangling, 1)
            self.assertTrue(any('vendor.plugin:missing' in item for item in errors))

    def test_allowlist_cannot_cover_an_added_duplicate(self):
        import json
        import tempfile
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=root / '.wippy', prefix='discovery-count-') as folder:
            tree = Path(folder)
            (tree / 'src').mkdir()
            (tree / 'build').mkdir()
            expression = 'id:match("^persisted%.owner:")'
            (tree / 'src/owner.lua').write_text('local first = ' + expression + '\nlocal second = ' + expression)
            (tree / 'build/registry_discovery_allowlist.json').write_text(json.dumps([
                {'path': 'src/owner.lua', 'expression': expression, 'count': 1,
                 'reason': 'M0 persisted identity decoder'}]))
            self.assertTrue(any('occurrence count' in item for item in check.audit(tree)))

    def test_unknown_imports_are_checked_without_a_namespace_prefix(self):
        import tempfile
        import layout_check
        import yaml
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=root / '.wippy', prefix='discovery-import-') as folder:
            tree = Path(folder)
            index = tree / 'src/wiring/_index.yaml'
            index.parent.mkdir(parents=True)
            (index.parent / 'helper.lua').write_text('return {}')
            index.write_text(yaml.safe_dump({'namespace': 'bee.wiring', 'entries': [
                {'name': 'helper', 'kind': 'library.lua', 'source': 'file://helper.lua',
                 'imports': {'foreign': 'vendor.library:missing'}}]}))
            errors, _, _, _, dangling = layout_check.audit(tree)
            self.assertEqual(dangling, 1)
            self.assertTrue(any('vendor.library:missing' in item for item in errors))

    def test_static_references_include_nested_environment_targets(self):
        import layout_check
        self.assertEqual(layout_check.REGISTRY_REFERENCE.findall('${env:vendor.resources:database}.client'),
                         ['vendor.resources:database'])
        self.assertEqual(layout_check.REGISTRY_REFERENCE.findall('"vendor.binding:root.service"'),
                         ['vendor.binding:root.service'])

    def test_native_targets_need_a_registration_declaration(self):
        import tempfile
        import layout_check
        import yaml
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=root / '.wippy', prefix='discovery-native-') as folder:
            tree = Path(folder)
            index = tree / 'src/wiring/_index.yaml'
            index.parent.mkdir(parents=True)
            index.write_text(yaml.safe_dump({'namespace': 'bee.wiring', 'entries': [
                {'name': 'selection', 'kind': 'ns.requirement', 'targets': [
                    {'entry': 'vendor.native:environment', 'path': '.storage'}]}]}))
            native = tree / 'native'
            native.mkdir()
            declaration = native / 'component.go'
            declaration.write_text('package native\nconst StorageID = "vendor.native:environment"\n'
                'func registryID() registry.ID { return registry.ParseID(StorageID) }\n'
                'func register() { environment.RegisterStorage(registryID(), storage) }\n')
            self.assertEqual(layout_check.audit(tree)[4], 0)
            declaration.write_text('package native\nconst StorageID = "vendor.native:environment"\n'
                '// environment.RegisterStorage(registryID(), storage)\n')
            self.assertEqual(layout_check.audit(tree)[4], 1)
