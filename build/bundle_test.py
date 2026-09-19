# SPDX-License-Identifier: MIT
"""Packaging regressions: ownership and publication of complete generations."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import bundle


class BundleTest(unittest.TestCase):
    def setUp(self):
        self.plan = {"schema": 1, "modules": [
            {"module": "bee/bee", "root": "bee", "namespaces": ["bee", "bee.hive_manager"]},
            {"module": "bee/hive", "root": "bee.hive", "namespaces": ["bee.hive", "bee.hive.telemetry"]}]}
        self.entries = {"bee:definition": "ns.definition", "bee.hive_manager:app": "process.lua",
                        "bee.hive:definition": "ns.definition", "bee.hive.telemetry:read": "function.lua"}

    def test_every_database_requires_a_state_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entries = [
                {"name": "path", "kind": "env.variable", "variable": "BEE_WORKSPACE_DB"},
                {"name": "workspace", "kind": "db.sql.sqlite", "file": "${env:bee:path}"},
                {"name": "client", "kind": "db.sql.sqlite", "file": "${env:bee:path}.client"},
                {"name": "governance_path", "kind": "env.variable", "variable": "BEE_GOVERNANCE_DB"},
                {"name": "governance", "kind": "db.sql.sqlite", "file": "${env:bee:governance_path}"},
            ]
            (root / "_index.yaml").write_text(bundle.yaml.safe_dump({"namespace": "bee", "entries": entries}))
            app = {"data": {"BEE_WORKSPACE_DB": "workspace.db"}}
            with self.assertRaisesRegex(ValueError, "BEE_GOVERNANCE_DB"):
                bundle.state_bindings(root, app)
            app["data"]["BEE_GOVERNANCE_DB"] = "governance.db"
            self.assertEqual(bundle.state_bindings(root, app), {
                "bee:workspace": "workspace.db", "bee:client": "workspace.db.client",
                "bee:governance": "governance.db"})
            for path in ("../outside.db", "/tmp/outside.db", "folder/../../outside.db"):
                app["data"]["BEE_GOVERNANCE_DB"] = path
                with self.assertRaisesRegex(ValueError, "inside the selected state directory"):
                    bundle.state_bindings(root, app)
            entries[-1]["file"] = ".wippy/governance.db"
            (root / "_index.yaml").write_text(bundle.yaml.safe_dump({"namespace": "bee", "entries": entries}))
            with self.assertRaisesRegex(ValueError, "state-bound environment path"):
                bundle.state_bindings(root, app)

    def test_exact_ownership_not_prefix_guess(self):
        owners = bundle.ownership(self.plan, self.entries)
        self.assertEqual(owners["bee.hive_manager"], "bee/bee")
        self.assertEqual(owners["bee.hive.telemetry"], "bee/hive")

    def test_build_metadata_uses_manifest_pins_and_staged_source_revision(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            manifest = {"runtime": {"repository": "https://runtime.example", "commit": "r" * 40},
                        "native": [{"module": "github.com/example/native", "version": "v1.2.3"}]}
            with patch.object(bundle, "source_revision", return_value="b" * 40 + "-dirty"):
                bundle.write_build_metadata(source, manifest, "0.1.0", Path(temporary))
            generated = (source / "src/apps/settings/build_info.lua").read_text()
            self.assertIn('version = "0.1.0"', generated)
            self.assertIn('build = "bbbbbbbbbbbb-dirty"', generated)
            self.assertIn('source_revision = "' + "b" * 40 + '-dirty"', generated)
            self.assertIn('runtime = "https://runtime.example"', generated)
            self.assertIn('runtime_commit = "' + "r" * 40 + '"', generated)
            self.assertIn('native_version = "v1.2.3"', generated)

    def test_about_distinguishes_patched_runtime_builds(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            manifest = {"runtime": {"repository": "runtime", "commit": "a" * 40,
                        "patches": [{"sha256": "b" * 64}]}}
            with patch.object(bundle, "source_revision", return_value="c" * 40 + "-dirty"):
                bundle.write_build_metadata(source, manifest, "0.1.0", source)
            generated = (source / "src/apps/settings/build_info.lua").read_text()
            self.assertIn("a" * 40 + " + patch " + "b" * 12, generated)
            self.assertIn('build = "cccccccccccc-dirty"', generated)

    def test_new_namespace_requires_explicit_owner(self):
        self.entries["bee.new:app"] = "process.lua"
        with self.assertRaisesRegex(ValueError, "unowned=.*bee.new"):
            bundle.ownership(self.plan, self.entries)

    def test_duplicate_and_missing_namespace_rejected(self):
        for namespace in ("bee", "bee.missing"):
            with self.subTest(namespace=namespace):
                plan = copy.deepcopy(self.plan)
                plan["modules"][1]["namespaces"].append(namespace)
                with self.assertRaises(ValueError):
                    bundle.ownership(plan, self.entries)

    def test_child_root_is_not_a_second_package(self):
        self.entries["bee.hive.telemetry:definition"] = "ns.definition"
        with self.assertRaisesRegex(ValueError, "needs exactly root"):
            bundle.ownership(self.plan, self.entries)

    def test_package_identity_is_explicit(self):
        self.plan["modules"][1]["module"] = "bee/placement_native"
        with self.assertRaisesRegex(ValueError, "invalid package identity"):
            bundle.ownership(self.plan, self.entries)

    def test_embed_selection_rejects_wildcards_host_paths_and_symlinks(self):
        for selected, directory, symlink in [("*", "assets", False),
                                              ("bee:assets", "/", False),
                                              ("bee:assets", "assets", True)]:
            with self.subTest(selected=selected, directory=directory, symlink=symlink), \
                 tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / "snapshot"
                (source / "src").mkdir(parents=True)
                (source / "wippy.yaml").write_text(bundle.yaml.safe_dump({"embed": [selected]}))
                (source / "src/_index.yaml").write_text(bundle.yaml.safe_dump({"namespace": "bee", "entries": [
                    {"name": "assets", "kind": "fs.directory", "directory": directory}]}))
                (root / "assets").mkdir()
                if symlink:
                    (root / "assets" / "outside").symlink_to(root / "source-secret")
                with self.assertRaises(ValueError):
                    bundle.freeze_assets(root, source, {"bee:assets": "fs.directory"})

    def test_failed_lint_or_pack_preserves_previous_bundle(self):
        for failed_operation in ("lint", "pack"):
            with self.subTest(operation=failed_operation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "src").mkdir()
                (root / "wippy.lock").write_text("directories: {src: ./src, modules: .wippy}\n")
                for name in ("wippy.yaml", ".wippy.yaml"):
                    (root / name).write_text("{}\n")
                manifest = root / "wippy.build.json"
                manifest.write_text(json.dumps({"runtime": {"patches": []}, "application": {
                    "module": "bee/bee", "packs": [{"module": "bee/bee", "version": "0.1.0"}]}}))
                original = manifest.read_bytes()
                plan = root / "modules.json"
                plan.write_text(json.dumps(self.plan))
                output = root / "bundle.json"
                output.write_text("previous generation\n")

                def fail(runtime, cwd, operation, *args):
                    if operation == failed_operation:
                        raise RuntimeError("injected build failure")

                with patch.object(bundle, "inventory", return_value=self.entries), \
                     patch.object(bundle, "loaded", return_value=self.entries), \
                     patch.object(bundle, "run", side_effect=fail):
                    with self.assertRaisesRegex(RuntimeError, "injected build failure"):
                        bundle.prepare(root, manifest, plan, output, root / "runtime")
                self.assertEqual(output.read_text(), "previous generation\n")
                self.assertEqual(manifest.read_bytes(), original)
                self.assertFalse(list(root.glob(".bee-bundle-*")))

    def test_sealed_generation_keeps_patch_bytes_and_rejects_changed_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "src").mkdir()
            (root / "wippy.lock").write_text("directories: {src: ./src, modules: .wippy}\n")
            for name in ("wippy.yaml", ".wippy.yaml"):
                (root / name).write_text("{}\n")
            upstream = root / "runtime.patch"
            upstream.write_text("// SPDX-License-Identifier: MPL-2.0\npatch bytes\n")
            manifest = root / "wippy.build.json"
            manifest.write_text(json.dumps({"runtime": {"patches": [{
                "path": "runtime.patch", "sha256": bundle.digest(upstream)}]}, "application": {
                    "module": "bee/bee", "packs": [{"module": "bee/bee", "version": "0.1.0"}]}}))
            original = manifest.read_bytes()
            plan = root / "modules.json"
            plan.write_text(json.dumps(self.plan))
            output = root / "dist" / "bundle.json"
            owners = bundle.ownership(self.plan, self.entries)

            def pack(runtime, cwd, operation, *args):
                if operation == "pack":
                    target = Path(args[0])
                    module = "bee/" + target.stem
                    target.write_text(json.dumps({identity: kind for identity, kind in self.entries.items()
                                                  if owners[identity.split(":")[0]] == module}))

            def loaded(runtime, cwd):
                if cwd.name == "source":
                    return self.entries
                lock = bundle.yaml.safe_load((cwd / "wippy.lock").read_text())
                return json.loads(Path(lock["directories"]["src"]).read_text())

            with patch.object(bundle, "inventory", return_value=self.entries), \
                 patch.object(bundle, "loaded", side_effect=loaded), \
                 patch.object(bundle, "run", side_effect=pack):
                bundle.prepare(root, manifest, plan, output, root / "runtime")
                sealed = output.read_bytes()
                result = json.loads(sealed)
                inputs = result["application"]["packs"] + result["runtime"]["patches"]
                for item in inputs:
                    self.assertEqual(bundle.digest(output.parent / item["path"]), item["sha256"])
                self.assertEqual((output.parent / result["runtime"]["patches"][0]["path"]).read_bytes(),
                                 upstream.read_bytes())
                bundle.prepare(root, manifest, plan, output, root / "runtime")
                self.assertEqual(output.read_bytes(), sealed)
                self.assertEqual(len(list((output.parent / "native-bundles").iterdir())), 1)
                upstream.write_text("changed after pinning\n")
                with self.assertRaisesRegex(ValueError, "patch checksum mismatch"):
                    bundle.prepare(root, manifest, plan, output, root / "runtime")
                self.assertEqual(output.read_bytes(), sealed)
                self.assertEqual(manifest.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
