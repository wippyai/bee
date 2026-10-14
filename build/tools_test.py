"""Toolchain cache identity contracts."""
from copy import deepcopy
import unittest
import json
from pathlib import Path
import tempfile
import os
import io
import shutil
import subprocess
import sys
from contextlib import redirect_stdout
from unittest.mock import patch

import tools


class ToolsTests(unittest.TestCase):
    def test_archive_tree_uses_cached_tools_without_a_marker_or_git_metadata(self):
        root = Path(__file__).resolve().parents[1] / ".wippy/tmp"
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            tree = directory / "archive"
            (tree / "build").mkdir(parents=True)
            for name in ("tools.py", "binary_identity.py"):
                shutil.copy2(Path(__file__).with_name(name), tree / "build" / name)
            manifest = {"runtime": {"module": "runtime", "version": "pin", "go": "1.27.1"}}
            value = tools.inputs(manifest, "builder", tools.platform_inputs())
            key = tools.content_key(value)
            cached = directory / "cache/bee-tools" / key
            cached.mkdir(parents=True)
            (cached / "wippy").write_text("cached toolchain")
            (tree / "wippy.build.json").write_text(json.dumps(manifest))
            environment = dict(os.environ, XDG_CACHE_HOME=str(directory / "cache"),
                               GIT_CEILING_DIRECTORIES=str(directory))
            command = [sys.executable, "build/tools.py", "--manifest", "wippy.build.json",
                       "--builder", "builder", "--bin", ".wippy/bin"]
            marker = tree / ".wippy/bin/bee-tools.json"
            self.assertFalse((tree / ".git").exists())
            self.assertFalse(marker.exists())
            result = subprocess.run(command, cwd=tree, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(marker.read_text())
            self.assertEqual(set(record), {"key", "inputs", "artifacts"})
            self.assertEqual(record["key"], key)
            self.assertEqual(record["artifacts"], {"wippy": tools.digest(cached / "wippy")})
            self.assertEqual((tree / ".wippy/bin/wippy").resolve(), cached / "wippy")
            record["source_revision"] = "unrelated-tool-source"
            marker.write_text(json.dumps(record))
            result = subprocess.run(command, cwd=tree, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("source_revision", json.loads(marker.read_text()))

    def test_key_tracks_every_toolchain_pin_but_ignores_application_pack_changes(self):
        manifest = {"runtime": {"module": "runtime", "version": "abc", "go": "1.27.1", "tags": ["fts5"]},
                    "native": [{"module": "native", "version": "def", "package": "host", "factory": "New"}],
                    "application": {"packs": [{"sha256": "old"}]}}
        platform = {"GOOS": "linux", "GOARCH": "amd64"}
        key = tools.content_key(tools.inputs(manifest, "builder", platform))
        manifest["application"]["packs"][0]["sha256"] = "new"
        self.assertEqual(key, tools.content_key(tools.inputs(manifest, "builder", platform)))
        for section, field in (("runtime", "version"), ("runtime", "go"), ("runtime", "tags"),
                               ("native", "version"), ("native", "factory")):
            changed = deepcopy(manifest)
            row = changed[section][0] if section == "native" else changed[section]
            row[field] = "changed"
            self.assertNotEqual(key, tools.content_key(tools.inputs(changed, "builder", platform)))
        self.assertNotEqual(key, tools.content_key(tools.inputs(manifest, "new-builder", platform)))
        self.assertNotEqual(key, tools.content_key(tools.inputs(manifest, "builder", {"GOOS": "darwin"})))
        self.assertEqual(tools.content_key({"a": 1, "b": 2}), tools.content_key({"b": 2, "a": 1}))

    def test_prebuilt_import_requires_matching_pins_and_untampered_artifacts(self):
        root = Path(__file__).resolve().parents[1] / ".wippy/tmp"
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            source = Path(directory) / "source"
            target = Path(directory) / "target"
            source.mkdir()
            target.mkdir()
            value = {"runtime": {"module": "github.com/wippyai/runtime", "version": "pinned"},
                     "native": [{"module": "github.com/wippyai/bee/native", "version": "v1.2.3"}],
                     "builder": "builder", "platform": {}}
            for name in ("wippy", "wippy-builder", "wippy.go.mod", "wippy.go.sum"):
                (source / name).write_text(name)
            (source / "wippy.go.mod").write_text("module fixture\nrequire github.com/wippyai/runtime v1.2.3\nrequire github.com/wippyai/bee/native v1.2.3\n")
            provenance = {"schema": 1, "mode": "toolchain", "manifest": value,
                          "artifacts": {"go.mod": tools.digest(source / "wippy.go.mod")}}
            (source / "wippy.provenance.json").write_text(json.dumps(provenance))
            record = {"key": tools.content_key(value), "inputs": value,
                      "artifacts": {p.name: tools.digest(p) for p in source.iterdir()}}
            (source / "bee-tools.json").write_text(json.dumps(record))
            self.assertFalse(tools.import_prebuilt(source, target, value, "different-pin"))
            self.assertTrue(tools.import_prebuilt(source, target, value, record["key"]))
            (source / "wippy").write_text("stale copied binary")
            with self.assertRaisesRegex(ValueError, "artifact mismatch"):
                tools.import_prebuilt(source, target, value, record["key"])

    def test_cross_compile_target_does_not_change_host_tool_binaries(self):
        root = Path(__file__).resolve().parents[1] / ".wippy/tmp"
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            manifest = directory / "manifest.json"
            manifest.write_text(json.dumps({"runtime": {"module": "runtime", "version": "pin", "go": "1.27.1"}}))
            native = {"GOOS": "darwin", "GOARCH": "arm64", "CGO_ENABLED": "1", "CC": "clang", "CXX": "clang++"}
            def build(command, **kwargs):
                for name in ("wippy", "wippy-builder", "wippy.go.mod", "wippy.go.sum", "wippy.provenance.json"):
                    (Path(kwargs["env"]["GOBIN"]) / name).write_text(name)
            with patch.dict(os.environ, {"XDG_CACHE_HOME": str(directory / "cache"), "GOOS": "darwin", "GOARCH": "amd64"}), \
                    patch.object(tools, "platform_inputs", return_value=native), \
                    patch.object(tools.shutil, "which", return_value="go"), \
                    patch.object(tools.subprocess, "run", side_effect=build) as run, \
                    patch("sys.argv", ["tools.py", "--manifest", str(manifest), "--builder", "builder", "--bin", str(directory / "bin")]), \
                    redirect_stdout(io.StringIO()):
                tools.main()
            self.assertEqual(run.call_count, 2)
            for call in run.call_args_list:
                self.assertEqual({k: call.kwargs["env"][k] for k in native}, native)

    def test_darwin_cache_identity_uses_the_host_architecture(self):
        with patch.object(tools.host_platform, "system", return_value="Darwin"), \
                patch.object(tools.host_platform, "machine", return_value="arm64"), \
                patch.dict(os.environ, {"GOOS": "linux", "GOARCH": "amd64"}):
            native = tools.platform_inputs()
        self.assertEqual((native["GOOS"], native["GOARCH"]), ("darwin", "arm64"))


if __name__ == "__main__":
    unittest.main()
