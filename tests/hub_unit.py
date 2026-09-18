"""Run the Hub component cases in the standard disposable Bee composition."""
import subprocess
import yaml
from workspace import RUNTIME, fixture_workspace

with fixture_workspace(managed_gateway=True) as folder:
    count = 0
    for manifest in (folder / "src/tests").rglob("_index.yaml"):
        document = yaml.safe_load(manifest.read_text())
        selected = str(document.get("namespace", "")).startswith(("bee.hub", "tests.hub_", "tests.modules"))
        changed = False
        for entry in document.get("entries", []):
            meta = entry.get("meta", {})
            if meta.get("type") == "test":
                if selected:
                    count += 1
                else:
                    meta["type"] = "test_support"
                    changed = True
        if changed:
            manifest.write_text(yaml.safe_dump(document, sort_keys=False))
    assert count > 0, "no Hub tests selected"
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True, timeout=120)
    subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal"],
                   cwd=folder, check=True, timeout=180)
