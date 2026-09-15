"""Run the real-actor Hive catalog-reader rejection against source."""
import os
from pathlib import Path
import subprocess
import yaml

from workspace import RUNTIME, fixture_workspace

TARGET = "bee.hive:desktop_reader_test"


def retain_reader_test(folder: Path):
    """Keep the actor test runnable without adding other test entries to its fixture."""
    for index in (folder / "src/tests").rglob("_index.yaml"):
        document = yaml.safe_load(index.read_text())
        changed = False
        for entry in document["entries"]:
            identity = f'{document["namespace"]}:{entry["name"]}'
            meta = entry.get("meta", {})
            if identity != TARGET and meta.get("type") == "test":
                meta["type"] = "test_support"
                changed = True
        if changed:
            index.write_text(yaml.safe_dump(document, sort_keys=False))


def run(runtime: Path, folder: Path):
    command = [str(runtime), "test", "--host", "bee:terminal"]
    subprocess.run(command, cwd=folder, check=True, env=os.environ.copy())


with fixture_workspace(managed_gateway=True) as folder:
    retain_reader_test(folder)
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True)
    run(RUNTIME, folder)
