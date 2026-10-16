"""Local runtime source builds pin local commits and keep the pack they built."""
import os
import unittest
from unittest.mock import patch

from build import local_manifest, prepare


def manifest(pack_sha):
    return {"runtime": {"module": "github.com/wippyai/runtime", "version": "released"},
            "application": {"packs": [
                {"module": "bee/bee", "version": "0.2.0-dev", "path": "dist/bee.wapp", "sha256": pack_sha},
                {"module": "wippy/test", "version": "0.4.19", "path": ".wippy/vendor/wippy/test-0.4.19.wapp", "sha256": "vendored"}]},
            "native": [{"module": local_manifest.NATIVE, "version": "released"}]}


class LocalManifestTests(unittest.TestCase):
    def test_pins_local_commits_over_the_release_manifest(self):
        pinned = local_manifest.pinned(manifest("released-pack"), None, "runtime-head", "native-head")
        self.assertEqual(pinned["runtime"]["version"], "runtime-head")
        self.assertEqual(pinned["native"][0]["version"], "native-head")
        self.assertEqual(pinned["application"]["packs"][0]["sha256"], "released-pack")

    def test_keeps_the_application_pack_a_local_build_recorded(self):
        built = manifest("locally-built-pack")
        pinned = local_manifest.pinned(manifest("released-pack"), built, "runtime-head", "native-head")
        self.assertEqual(pinned["application"]["packs"][0]["sha256"], "locally-built-pack")
        self.assertEqual(pinned["application"]["packs"][1]["sha256"], "vendored")

    def test_takes_vendored_packs_from_the_release_manifest(self):
        stale = manifest("locally-built-pack")
        stale["application"]["packs"][1]["sha256"] = "older-vendored"
        pinned = local_manifest.pinned(manifest("released-pack"), stale, "runtime-head", "native-head")
        self.assertEqual(pinned["application"]["packs"][1]["sha256"], "vendored")


class PrepareManifestTests(unittest.TestCase):
    def test_assembles_with_the_manifest_the_build_selected(self):
        with patch.dict(os.environ, {"MANIFEST": "wippy.build.local.json"}):
            self.assertEqual(prepare.manifest(), "wippy.build.local.json")
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(prepare.manifest(), "wippy.build.json")


if __name__ == "__main__":
    unittest.main()
