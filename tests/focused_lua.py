"""Run selected Lua test entries in Bee's disposable composition."""
import subprocess
import sys
import yaml

from workspace import RUNTIME, fixture_workspace


def main(namespace, selected_names):
    with fixture_workspace(managed_gateway=True) as folder:
        selected = []
        for manifest in (folder / "src/tests").rglob("_index.yaml"):
            document = yaml.safe_load(manifest.read_text())
            for entry in document.get("entries", []):
                if entry.get("meta", {}).get("type") != "test":
                    continue
                test_id = f"{document.get('namespace', '')}:{entry.get('name', '')}"
                if document.get("namespace") == namespace and entry.get("name") in selected_names:
                    selected.append(test_id)
                else:
                    entry["meta"]["type"] = "test_support"
            manifest.write_text(yaml.safe_dump(document, sort_keys=False))
        if len(selected) != len(selected_names):
            raise SystemExit(f"expected {len(selected_names)} tests in {namespace}, found {selected}")
        subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", *selected],
                       cwd=folder, check=True, timeout=180)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("usage: focused_lua.py NAMESPACE TEST_ENTRY...")
    main(sys.argv[1], sys.argv[2:])
