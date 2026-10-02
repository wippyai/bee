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
            'if entry.id:find("bee.", 1, true) then return true end',
            'local ref = namespace .. ":" .. "configure"',
            'local ref = binding_ref:gsub(":", ".")',
            'local ref = binding_ref:match("^(.*)%.binding:binding$")',
            'local rows = pinned:find({[".ns"] = namespace})',
            'local rows = registry.find({[".name"] = "binding"})',
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
            'if path:sub(1, #root + 1) == root .. "/" then return path end',
            '-- if id:match("^bee%.") then return true end',
            'local example = [[ id:match("^bee%.") ]]',
            '''local example = 'id:match("^bee%.")' ''',
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
