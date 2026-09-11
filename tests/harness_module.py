"""Static harness dependency closure; not installation or execution acceptance."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME

# Exact reviewed dependencies outside the harness package. Growing this set
# requires review; do not let automatic traversal hide a new store/core import.
DEPENDENCIES = {
    "bee.driver.codex:configuration", "bee.driver.kit:framing",
    "bee.driver.transport:stream_json", "bee.driver:profile", "bee.driver:types",
    "bee.gateway:configuration", "bee.placement.native:protocol",
    "bee.placement:types", "bee.threads.records:bounds", "bee.threads.records:canonical",
}


def stage(folder, broken):
    entries = {}
    for path in (ROOT / "src").rglob("_index.yaml"):
        document = yaml.safe_load(path.read_text())
        for entry in document["entries"]:
            entries[document["namespace"] + ":" + entry["name"]] = (entry, path)
    harness = {key for key in entries if key.startswith("bee.harness:") or key.startswith("bee.harness.")}
    selected = set()
    pending = list(harness)
    while pending:
        identity = pending.pop()
        if identity in selected:
            continue
        selected.add(identity)
        pending.extend(entries[identity][0].get("imports", {}).values())
    assert selected - harness == DEPENDENCIES, selected - harness
    grouped = {}
    for identity in sorted(selected):
        entry, source = entries[identity]
        namespace = identity.split(":")[0]
        grouped.setdefault(namespace, []).append(entry)
        target = folder / "src" / namespace
        target.mkdir(parents=True, exist_ok=True)
        for key in ("source", "readme"):
            value = entry.get(key, "")
            if value.startswith("file://"):
                relative = value.removeprefix("file://")
                destination = target / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source.parent / relative, destination)
        if broken and identity == "bee.harness:process_host":
            entry["targets"] = [{"entry": "bee.harness:missing_ref", "path": ".host_ref"}]
    for namespace, items in grouped.items():
        (folder / "src" / namespace / "_index.yaml").write_text(yaml.safe_dump(
            {"version": "1.0", "namespace": namespace, "entries": items}, sort_keys=False))
    shutil.copytree(ROOT / "tests/modules/harness/src", folder / "src/host")
    (folder / "wippy.lock").write_text("directories:\n  src: ./src\n")
    (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")


def run(folder, *args):
    result = subprocess.run([str(RUNTIME), *args], cwd=folder,
                            capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    return output


def main():
    for broken in (False, True):
        with tempfile.TemporaryDirectory(prefix="bee-harness-module-") as directory:
            folder = Path(directory)
            stage(folder, broken)
            run(folder, "lint")
            output = run(folder, "run", "harness-isolation")
            expected = "unlinked host refused before effects" if broken else "linked host; request refused before effects"
            assert expected in output, output
    print("Harness static closure: isolated boot, empty catalog, linked host and unlinked refusal; no execution/install claim")


if __name__ == "__main__":
    main()
