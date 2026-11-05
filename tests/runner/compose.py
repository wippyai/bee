"""Compose the application copy and fixtures the Lua suites load; seams come from the bee.process:seams binding."""
from pathlib import Path
import fcntl
import gzip
import shutil
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tests"
COMPOSITION = TESTS / ".wippy/composition"
# bee/drivers, composed beside Bee from the repository's drivers module.
DRIVERS_COMPOSITION = TESTS / ".wippy/composition-drivers"


def host_environment():
    """The unit host facts, with the Claude fixture as the installed claude."""
    document = yaml.safe_load((TESTS / "fixtures/harness/host.yaml").read_text())
    environment = next(entry for entry in document["entries"] if entry["name"] == "environment")
    environment["data"]["values"]["claude"] = str(TESTS / "fixtures/harness/bin/claude")
    environment["data"]["values"]["opencode"] = str(TESTS / "fixtures/harness/bin/opencode")
    target = COMPOSITION / "src/harness/host/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(yaml.safe_dump(document, sort_keys=False))


def compose_root_pack():
    """Expand the immutable published package snapshot for the Lua inspection suites."""
    encoded = gzip.decompress((TESTS / "fixtures/hub/root_pack.json.gz").read_bytes()).decode()
    assert "]====]" not in encoded
    (TESTS / "lua/hub/root_pack_data.lua").write_text(
        "return {encoded = [====[" + encoded + "]====]}\n")


def compose():
    compose_root_pack()
    shutil.rmtree(COMPOSITION, ignore_errors=True)
    shutil.rmtree(DRIVERS_COMPOSITION, ignore_errors=True)
    src = COMPOSITION / "src"
    shutil.copytree(ROOT / "src", src)
    shutil.copytree(ROOT / "drivers/src", DRIVERS_COMPOSITION)
    # The composition is a module root like the repository: its manifest
    # beside src, so module-relative directories resolve as they do in a pack.
    shutil.copy(ROOT / "wippy.yaml", COMPOSITION / "wippy.yaml")
    shutil.copytree(TESTS / "fixtures/memory", src / "test_memory")
    shutil.copytree(TESTS / "fixtures/persist/retained", src / "test_retained")
    host_environment()


def main():
    (TESTS / ".wippy").mkdir(exist_ok=True)
    with (TESTS / ".wippy/composition.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        compose()


if __name__ == "__main__":
    sys.exit(main())
