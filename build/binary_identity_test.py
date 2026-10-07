import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("binary_identity", ROOT / "build/binary_identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class BinaryIdentityTest(unittest.TestCase):
    def setUp(self):
        self.manifest = {"runtime": {"module": "github.com/wippyai/runtime", "version": "2bb9e144ab062548be9e5914a84f4c38cf39f797"},
                         "native": [{"module": "github.com/wippyai/bee/native", "version": "v1.2.3"}]}
        self.go_mod = b"module wippy.build/bee\n\ngo 1.27.0\n\nrequire (\n github.com/wippyai/runtime v0.1.14-0.20261007011850-2bb9e144ab06\n github.com/wippyai/bee/native v1.2.3\n)\n"
        self.provenance = {"schema": 1, "mode": "toolchain", "manifest": self.manifest,
                           "artifacts": {"go.mod": hashlib.sha256(self.go_mod).hexdigest()}}

    def test_generates_complete_pack_identity_from_verified_resolved_versions(self):
        entry = identity.generate(self.manifest, self.provenance, self.go_mod, "0.2.0-alpha.1", "revision")
        self.assertEqual(entry["kind"], "registry.entry")
        self.assertEqual(entry["meta"]["type"], "bee.binary_identity")
        data = entry["data"]
        self.assertEqual(set(data), {"version", "build", "source", "source_revision", "runtime", "runtime_commit",
                                     "native", "native_version", "website", "native_components"})
        self.assertEqual(data["runtime_commit"], "v0.1.14-0.20261007011850-2bb9e144ab06")
        self.assertEqual(data["native_components"], [{"package": "github.com/wippyai/bee/native", "version": "v1.2.3"}])
        self.assertEqual(data["native_version"], "v1.2.3")

    def test_refuses_stale_pins_and_tampered_resolutions(self):
        for mutate in (lambda p: p["manifest"]["runtime"].update(version="another-commit"),
                       lambda p: p["artifacts"].update({"go.mod": "0" * 64})):
            provenance = json.loads(json.dumps(self.provenance))
            mutate(provenance)
            with self.assertRaises(ValueError):
                identity.generate(self.manifest, provenance, self.go_mod, "0.2.0-alpha.1", "revision")

    def test_refuses_module_replacements_and_missing_native_modules(self):
        for text in (self.go_mod + b"replace github.com/wippyai/bee/native => ../native\n",
                     self.go_mod.replace(b" github.com/wippyai/bee/native v1.2.3\n", b"")):
            provenance = json.loads(json.dumps(self.provenance))
            provenance["artifacts"]["go.mod"] = hashlib.sha256(text).hexdigest()
            with self.assertRaises(ValueError):
                identity.generate(self.manifest, provenance, text, "0.2.0-alpha.1", "revision")


if __name__ == "__main__":
    unittest.main()
