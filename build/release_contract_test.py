from pathlib import Path
import unittest
import yaml
import json

ROOT = Path(__file__).resolve().parents[1]


class ReleaseContractTest(unittest.TestCase):
    def test_development_versions_outrank_legacy_hub_release_line(self):
        self.assertEqual(yaml.safe_load((ROOT / "wippy.yaml").read_text())["version"], "0.2.0-dev")
        self.assertIn("VERSION ?= 0.2.0-dev", (ROOT / "Makefile").read_text())
        manifest = json.loads((ROOT / "wippy.build.json").read_text())
        bee = [p for p in manifest["application"]["packs"] if p["module"] == "bee/bee"]
        self.assertEqual(bee[0]["version"], "0.2.0-dev")


if __name__ == "__main__":
    unittest.main()
