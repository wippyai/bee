"""Run sync, approval and inbox cases with the normal disposable test composition."""
import os
import subprocess
import yaml
from workspace import RUNTIME, fixture_workspace


with fixture_workspace(managed_gateway=True) as folder:
    selected = {"bee.sync", "bee.approvals", "bee.inbox"}
    count = 0
    for manifest in (folder / "src/tests").rglob("_index.yaml"):
        document = yaml.safe_load(manifest.read_text())
        changed = False
        for entry in document.get("entries", []):
            meta = entry.get("meta", {})
            if meta.get("type") == "test":
                if document.get("namespace") in selected:
                    count += 1
                else:
                    meta["type"] = "test_support"
                    changed = True
        if changed:
            manifest.write_text(yaml.safe_dump(document, sort_keys=False))
    assert count > 0, "no subsystem tests selected"
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True, timeout=120)
    environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
                   "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers")}
    subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal"],
                   cwd=folder, check=True, env=environment, timeout=180)
