"""Inspect the sealed boot/core artifacts and their host-selected composition."""
import json
from pathlib import Path
import subprocess
import sys

import yaml
from workspace import ROOT, RUNTIME


def entries(*packs):
    result = subprocess.run(["go", "-C", str(ROOT / "native"), "run", "-mod=readonly",
                             str(ROOT / "build/inspect_pack.go"), *map(str, packs)],
                            check=True, capture_output=True, text=True, timeout=30)
    return {entry["id"]: entry for entry in json.loads(result.stdout)}


def main(deployment, manifest):
    deployment = Path(deployment).resolve()
    baseline = yaml.safe_load((deployment / "wippy.lock").read_text())
    selected = yaml.safe_load((deployment / "hub/wippy.lock").read_text())
    baseline_rows = {row["name"]: row for row in baseline["modules"]}
    embedded = json.loads(Path(manifest).read_text())["application"]["packs"]
    assert {(pack["module"], pack["version"], "sha256:" + pack["sha256"]) for pack in embedded} == \
        {(row["name"], row["version"], row["hash"]) for row in baseline["modules"]}, "builder baseline identity differs from its lock"
    selected_rows = {row["name"]: row for row in selected["modules"]}
    assert baseline_rows.keys() == selected_rows.keys(), "embedded baseline pack list changed"
    for name, row in baseline_rows.items():
        if name != "bee/bee":
            assert row == selected_rows[name], f"component artifact differs: {name}"
    boot_version = baseline_rows["bee/bee"]["version"]
    version = selected_rows["bee/bee"]["version"]
    release, _, metadata = version.partition("+")
    base, _, prerelease = release.partition("-")
    expected_boot = base + "-0.boot" + ("." + prerelease if prerelease else "") + ("+" + metadata if metadata else "")
    assert boot_version == expected_boot, "boot/core identities are not distinct"
    boot = entries(deployment / f".wippy/vendor/bee/bee-{boot_version}.wapp")
    core = entries(deployment / f"hub/.wippy/vendor/bee/bee-{version}.wapp")
    dependencies = {identity: entry for identity, entry in boot.items() if entry["kind"] == "ns.dependency"}
    assert dependencies, "boot composition lost its selected closure"
    for identity, entry in core.items():
        assert entry["kind"] != "ns.dependency" or not entry["data"]["component"].startswith("bee/"), \
            "Bee self-update must leave component selection to host roots: " + identity
    host = yaml.safe_load((deployment / "hub/src/deps/_index.yaml").read_text())
    authored = {host["namespace"] + ":" + entry["name"]: entry for entry in host["entries"]}
    assert authored.keys() == dependencies.keys(), "host selection differs from the baseline closure"
    for identity, entry in dependencies.items():
        expected = {key: value for key, value in authored[identity].items() if key not in {"name", "kind", "meta"}}
        assert entry["data"] == expected, f"host parameters differ: {identity}"
    registered = subprocess.run([str(RUNTIME), "registry", "list", "--registry-meta", "--ns", "bee.deps", "--json"],
                                cwd=deployment / "hub", check=True, capture_output=True, text=True, timeout=30)
    roots = json.loads(registered.stdout)
    assert {root["id"] for root in roots} == authored.keys(), "host roots did not load"
    assert all(root["registry"].get("owner", "") == "" and root["registry"].get("root") is True for root in roots), \
        "component selection is still owned by the core package"
    assert core.keys() == boot.keys() - authored.keys(), "core lost entries outside host composition"
    for identity, entry in core.items():
        assert entry == boot[identity], f"core implementation differs: {identity}"
    composed = entries(*(deployment / "hub/.wippy/vendor" / f"{name}-{row['version']}.wapp"
                         for name, row in selected_rows.items()))
    targets = 0
    for identity, entry in composed.items():
        if entry["kind"] == "ns.requirement":
            for target in entry["data"].get("targets", []):
                reference = target["entry"]
                if ":" not in reference:
                    reference = identity.split(":", 1)[0] + ":" + reference
                assert reference in composed, f"requirement target does not resolve: {identity} -> {reference}"
                targets += 1
    print(f"Core artifact PASS: {len(core)} core entries, 0 Bee dependencies; {len(authored)} exact host roots; {len(baseline_rows)} baseline packs; {targets} resolved targets, 0 dangling.")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
