# SPDX-License-Identifier: MIT
"""Check the mechanically decidable placement rules in development/conventions.md."""
import argparse
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SDK = {"application": "bee.app"}
NATIVE_ENTRIES = {"bee.harness.host:environment"}
ROOT_ENTRIES = json.loads((ROOT / "build/layout_roots.json").read_text())
REGISTRY_REFERENCE = re.compile(r"(?<![A-Za-z0-9_.-])[A-Za-z][A-Za-z0-9_.-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*(?![A-Za-z0-9_.:-])")
ROOT_DECLARATIONS = {"ns.definition", "ns.dependency", "ns.requirement", "contract.definition"}


def audit(root):
    errors, entries, sources = [], {}, set()
    component_roots = {SDK.get(index.parent.parent.name, "bee." + index.parent.parent.name.replace("-", "."))
                       for index in (root / "modules").glob("*/src/_index.yaml")}
    documents = {}
    graph = defaultdict(set)
    groups = defaultdict(set)
    indexes = [*sorted((root / "src").rglob("_index.yaml")),
               *sorted((root / "modules").glob("*/src/**/_index.yaml"))]
    for index in indexes:
        relative = index.relative_to(root)
        module = relative.parts[1] if relative.parts[0] == "modules" else None
        source_root = root / "modules" / module / "src" if module else root / "src"
        document = yaml.safe_load(index.read_text())
        documents[index] = document
        namespace = document["namespace"]
        expected = SDK.get(module, "bee." + module.replace("-", ".")) if module else "bee"
        children = index.parent.relative_to(source_root).parts
        expected += "".join("." + child for child in children)
        if namespace != expected:
            errors.append(f"{relative}: folder namespace is {expected}, declared {namespace}")
        if "_" in namespace or any("_" in child for child in children):
            errors.append(f"{relative}: namespace folders and namespaces cannot contain underscores")
        if module and "host" in children:
            errors.append(f"{relative}: component wiring belongs beside its component, not in host/")
        if not (source_root / "_index.yaml").is_file():
            errors.append(f"{relative}: component has no root _index.yaml")
        for entry in document.get("entries", []):
            identity = namespace + ":" + entry["name"]
            if namespace == "bee" or namespace in component_roots:
                documented = ROOT_ENTRIES.get(namespace, {}).get(entry["name"])
                allowed = entry["kind"] == documented if documented is not None else namespace != "bee" and entry["kind"] in ROOT_DECLARATIONS
                if not allowed:
                    errors.append(f"{identity}: root entry is outside the documented composition set; place it in its owner's child namespace")
            if identity in entries:
                errors.append(f"{relative}: duplicate registry identity {identity}")
            entries[identity] = (index, entry)
            for group in entry.get("groups", []):
                groups[namespace + ":" + group].add(identity)
            graph[identity].update(REGISTRY_REFERENCE.findall(yaml.safe_dump(entry)))
            source = entry.get("source", "")
            if source.startswith("file://"):
                path = index.parent / source[7:]
                if path.parent != index.parent or not path.is_file():
                    errors.append(f"{identity}: source must exist beside its declaring index: {source}")
                sources.add(path.resolve())
                if path.is_file():
                    graph[identity].update(REGISTRY_REFERENCE.findall(path.read_text()))
                if module and module != "application" and path.name in {"app.lua", "view.lua"} and children != ("app",):
                    errors.append(f"{identity}: application entry/rendering source belongs in src/app")
            if module and source == "file://types.lua" and children:
                errors.append(f"{identity}: shared domain types belong in the component root")
            if module and entry["kind"] == "fs.directory":
                directory = entry.get("directory", "")
                if directory and not directory.startswith(("/", "${")) and entry.get("base") != "project":
                    errors.append(f"{identity}: a project-relative module directory requires base: project")
            if entry.get("kind") in {"ns.definition", "contract.definition"} and children and module and not (module == "workspace" and children == ("catalog",) and entry["kind"] == "contract.definition"):
                errors.append(f"{identity}: component definition belongs in its source root")
            if module and entry.get("meta", {}).get("type") == "bee.app" and children != ("app",):
                errors.append(f"{identity}: application identity belongs in src/app")
            if module and entry["kind"] == "function.lua" and children not in {("app",), ("binding",), ("api",), ("service",), ("traits",)}:
                errors.append(f"{identity}: callable implementations belong in src/binding, api, service or traits")
            if module and entry["kind"] in {"process.lua", "process.service"} and children not in {("app",), ("service",)}:
                errors.append(f"{identity}: long-running processes belong in src/service")
    for identity, (_, entry) in entries.items():
        if entry["kind"] == "contract.binding":
            for contract in entry.get("contracts", []):
                for target in contract.get("methods", {}).values():
                    if target in entries:
                        index, method = entries[target]
                        if index.relative_to(root).parts[0] == "modules" and method["kind"] == "function.lua" and index.parent.name != "binding":
                            errors.append(f"{target}: contract method implementations belong in src/binding")
    for index in sorted((root / "tests").rglob("_index.yaml")):
        document = yaml.safe_load(index.read_text())
        if "_" in document["namespace"]:
            errors.append(f"{index.relative_to(root)}: test overlay namespace cannot contain underscores")
    external_targets = set()
    if (root / "build/component-inventory-external.json").is_file():
        from component_inventory import load_external_proofs
        external, _ = load_external_proofs(documents)
        external_targets.update(external)
    dangling, targets = 0, 0
    for identity, (index, entry) in entries.items():
        refs = list(entry.get("imports", {}).values())
        if entry["kind"] == "contract.binding":
            for contract in entry.get("contracts", []):
                refs.append(contract["contract"])
                refs.extend(contract.get("methods", {}).values())
        if entry.get("meta", {}).get("type") == "bee.approval_policies":
            refs.extend(approver["definition_id"] for policy in entry.get("policies", [])
                        for approver in policy.get("approvers", [])
                        if isinstance(approver, dict) and "definition_id" in approver)
        if entry["kind"] == "ns.requirement":
            for target in entry.get("targets", []):
                ref = target["entry"]
                if ":" not in ref:
                    ref = identity.split(":", 1)[0] + ":" + ref
                if ref not in entries and ref not in NATIVE_ENTRIES and ref not in external_targets:
                    errors.append(f"{identity}: dangling requirement target {ref}")
                    dangling += 1
            targets += len(entry.get("targets", []))
            if isinstance(entry.get("default"), list) and any(
                target["path"].rstrip().endswith("+=") for target in entry.get("targets", [])
            ):
                errors.append(f"{identity}: append requirement cannot default to an array element")
        for ref in refs:
            if ":" in ref and ref not in entries and ref not in NATIVE_ENTRIES and ref not in external_targets:
                errors.append(f"{identity}: dangling linker/import target {ref}")
                dangling += 1
        if index.relative_to(root).parts[0] == "modules" and entry["kind"] == "ns.requirement":
            for ref in REGISTRY_REFERENCE.findall(str(entry.get("default", ""))):
                if ref in entries and entries[ref][0].relative_to(root).parts[0] != "modules":
                    errors.append(f"{identity}: module requirement default names host entry {ref}")
    for edges in graph.values():
        for group, members in groups.items():
            if group in edges:
                edges.update(members)
    roots = set()
    for folder in [root / "tests", root / "docs", root / "native"]:
        for path in folder.rglob("*"):
            if path.is_file() and path.suffix in {".lua", ".yaml", ".py", ".go", ".md", ".sh"}:
                text = path.read_text()
                roots.update(REGISTRY_REFERENCE.findall(text))
                for reference in set(re.findall(r"modules/[a-z-]+/src/[A-Za-z0-9_./-]+\.lua", text)):
                    if not (root / reference).is_file():
                        errors.append(f"{path.relative_to(root)}: dangling production source reference {reference}")
    roots.update(identity for identity, (_, entry) in entries.items()
                 if entry["kind"] in {"ns.definition", "ns.requirement", "ns.dependency", "process.service", "contract.binding", "http.endpoint"}
                 or entry.get("meta", {}).get("type") in {"bee.app", "bee.app_command", "bee.codex_provider", "agent.trait"} or entry.get("meta", {}).get("command"))
    reachable, pending = set(), list(roots & entries.keys())
    while pending:
        identity = pending.pop()
        if identity in reachable:
            continue
        reachable.add(identity)
        pending.extend(graph[identity] - reachable)
    for identity, (_, entry) in entries.items():
        if identity not in reachable:
            errors.append(f"{identity}: no path from composition, a public documented contract or tests")
    duplicates = defaultdict(list)
    for source_root in [root / "src", *sorted((root / "modules").glob("*/src"))]:
        for path in sorted(source_root.rglob("*.lua")):
            if path.resolve() not in sources:
                errors.append(f"{path.relative_to(root)}: orphan Lua source has no registry entry")
            duplicates[hashlib.sha256(path.read_bytes()).hexdigest()].append(path.relative_to(root))
    for paths in duplicates.values():
        if len(paths) > 1:
            errors.append("identical production Lua implementations: " + ", ".join(map(str, paths)))
    return errors, len(indexes), len(entries), targets, dangling


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors, namespaces, entries, targets, dangling = audit(args.root.resolve())
    for error in errors:
        print(error)
    print(f"Layout: {namespaces} namespaces, {entries} entries, {targets} requirement targets, {dangling} dangling; {len(errors)} violations")
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
