#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate and check Bee's source identity, resource, and handoff inventory."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = ROOT / "docs/development/component-inventory.json"
IDENTITIES_PATH = ROOT / "build/component-inventory-identities.json"
MIGRATIONS_PATH = ROOT / "build/component-inventory-migrations.json"
EXTERNAL_PATH = ROOT / "build/component-inventory-external.json"
BUDGET_PATH = ROOT / "build/root-src-lua-budget.txt"
PERSISTED_KINDS = {
    "contract.binding",
    "contract.definition",
    "db.sql.sqlite",
    "env.storage.memory",
    "env.storage.os",
    "env.variable",
    "exec.native",
    "fs.directory",
    "http.endpoint",
    "http.router",
    "http.service",
    "ns.definition",
    "ns.requirement",
    "process.host",
    "process.lua",
    "process.service",
    "registry.entry",
    "security.policy",
    "security.policy.expr",
    "terminal.host",
}
REGISTRY_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*:[A-Za-z][A-Za-z0-9_.-]*$")
NATIVE_ID = re.compile(r"\bbee(?:\.[A-Za-z0-9_.-]+)*:[A-Za-z][A-Za-z0-9_.-]*\b")
SCHEMA_TAG = re.compile(r"\b[A-Za-z][A-Za-z0-9_.-]*@[0-9]+\b")
TOPIC_VALUE = re.compile(r"^bee(?:\.[A-Za-z0-9_.-]+)+$")
MESSAGE_CALL = re.compile(r"\b(process\.listen|process\.send|channel\.send|message\.send)\s*\(")
STRING_ASSIGNMENT = re.compile(
    r"(?m)(?:local\s+)?((?:[A-Za-z_][A-Za-z0-9_]*\.)*[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*=\s*([\"'])(bee(?:\.[A-Za-z0-9_.-]+)+)\2"
)
LUA_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SQL_TABLE = re.compile(
    r"\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"
    r"(?!IF\s+NOT\s+EXISTS\b)(?:[\"`\[])?([A-Za-z_][A-Za-z0-9_]*)",
    re.IGNORECASE,
)
LEDGER_TABLE = re.compile(
    r"\b(?:MIGRATION_TABLE|table)\s*=\s*([\"'])([A-Za-z][A-Za-z0-9_]*_schema_migrations)\1"
)
HANDOFF_TARGET = re.compile(r"\bmake\s+([a-z][A-Za-z0-9_.-]*-check)\b")
PROPOSAL_EVIDENCE = re.compile(
    r"Hive supervisor handoff and generation rollback remain\s+proposals\."
)


def rel(path):
    return path.relative_to(ROOT).as_posix()


def read_yaml(path):
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ValueError(f"cannot read YAML source {rel(path)}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"expected a mapping in {rel(path)}")
    return value


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON source {rel(path)}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {rel(path)}")
    return value


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def iter_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from iter_strings(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from iter_strings(key)
            yield from iter_strings(item)


def source_roots():
    roots = [ROOT / "src"]
    roots.extend(sorted(path for path in (ROOT / "modules").glob("*/src") if path.is_dir()))
    return roots


def source_indexes():
    paths = []
    for source_root in source_roots():
        paths.extend(source_root.rglob("_index.yaml"))
    return sorted(paths)


def source_namespace(path, module_roots):
    source_root = path.parent
    while source_root.name != "src" and source_root != ROOT:
        source_root = source_root.parent
    if source_root == ROOT:
        raise ValueError(f"source index is outside a source root: {rel(path)}")
    relative = path.parent.relative_to(source_root)
    if source_root == ROOT / "src":
        base = "bee"
    else:
        base = module_roots.get(source_root)
        if base is None:
            raise ValueError(f"module root has no source index: {rel(source_root)}")
    child = ".".join(relative.parts)
    return base if not child else f"{base}.{child}"


def module_directory(path):
    relative = path.relative_to(ROOT)
    if relative.parts[0] == "modules":
        return ROOT / "modules" / relative.parts[1]
    return ROOT


def module_lock_path(module_root):
    if module_root == ROOT:
        return None
    return module_root / "wippy.lock"


def load_external_proofs(index_documents):
    proof = read_json(EXTERNAL_PATH)
    packages = proof.get("packages")
    if not isinstance(packages, list):
        raise ValueError(f"{rel(EXTERNAL_PATH)} must contain a packages list")
    external_entries = {}
    verified_packages = []
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("external package proof entries must be objects")
        component = package.get("component")
        version = package.get("version")
        digest = package.get("sha256")
        source_module = package.get("source_module")
        target_ids = package.get("target_ids")
        if not all(isinstance(value, str) and value for value in (component, version, digest, source_module)):
            raise ValueError("external package proof requires component, version, sha256, and source_module")
        if not isinstance(target_ids, list) or not all(isinstance(value, str) for value in target_ids):
            raise ValueError(f"external package proof for {component} requires target_ids")
        module_root = ROOT / source_module
        lock_path = module_lock_path(module_root)
        if lock_path is None or not lock_path.is_file():
            raise ValueError(f"external package proof has no lock file: {source_module}")
        lock = read_yaml(lock_path)
        locked = [
            item for item in lock.get("modules", []) or []
            if isinstance(item, dict)
            and item.get("name") == component
            and str(item.get("version")) == version
            and item.get("hash") == digest
        ]
        if len(locked) != 1:
            raise ValueError(f"{component}@{version} proof does not match exactly one pin in {rel(lock_path)}")
        dependencies = []
        for path, document in index_documents.items():
            if module_directory(path) != module_root:
                continue
            for entry in document.get("entries", []) or []:
                if not isinstance(entry, dict) or entry.get("kind") != "ns.dependency":
                    continue
                if entry.get("component") == component and str(entry.get("version")) == version:
                    dependencies.append(entry)
        if not dependencies:
            raise ValueError(f"{component}@{version} is not declared by {source_module} registry sources")
        component_namespace = component.replace("/", ".")
        for entry_id in target_ids:
            if not REGISTRY_ID.fullmatch(entry_id):
                raise ValueError(f"invalid external target id in proof: {entry_id}")
            namespace = entry_id.split(":", 1)[0]
            if namespace != component_namespace and not namespace.startswith(component_namespace + "."):
                raise ValueError(f"{entry_id} is outside the {component} namespace")
            if entry_id in external_entries:
                raise ValueError(f"duplicate external target proof: {entry_id}")
            external_entries[entry_id] = {
                "component": component,
                "version": version,
                "sha256": digest,
                "proof_source": rel(EXTERNAL_PATH),
            }
        verified_packages.append({
            "component": component,
            "version": version,
            "sha256": digest,
            "source_module": source_module,
            "target_ids": sorted(target_ids),
        })
    return external_entries, sorted(verified_packages, key=lambda item: item["component"])


def resolve_id(entry_id, entries, native_ids, external_entries):
    if entry_id in entries:
        return "registry source"
    if entry_id in native_ids:
        return "native source"
    if entry_id in external_entries:
        return "locked component"
    return None


def check_reference(entry_id, entries, native_ids, external_entries, label):
    resolved_by = resolve_id(entry_id, entries, native_ids, external_entries)
    if resolved_by is None:
        raise ValueError(f"unresolved registry reference {entry_id} at {label}")
    return resolved_by


def current_budget():
    try:
        value = BUDGET_PATH.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ValueError(f"cannot read root source budget {rel(BUDGET_PATH)}: {error}") from error
    if not value.isdigit():
        raise ValueError(f"{rel(BUDGET_PATH)} must contain one positive line count")
    return int(value)


def root_lua_line_count():
    count = 0
    for path in (ROOT / "src").rglob("*.lua"):
        count += len(path.read_text(encoding="utf-8").splitlines())
    return count


def call_arguments(text, opening_parenthesis):
    arguments = []
    argument_start = opening_parenthesis + 1
    stack = []
    quote = ""
    escaped = False
    closing = {"(": ")", "[": "]", "{": "}"}
    for index in range(opening_parenthesis + 1, len(text)):
        character = text[index]
        if quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = ""
            continue
        if character in {"'", '"'}:
            quote = character
        elif character in closing:
            stack.append(closing[character])
        elif stack and character == stack[-1]:
            stack.pop()
        elif not stack and character == ",":
            arguments.append(text[argument_start:index].strip())
            argument_start = index + 1
        elif not stack and character == ")":
            arguments.append(text[argument_start:index].strip())
            return arguments
    return []


def collect_topics(paths):
    direct = defaultdict(set)
    used_symbols = set()
    assignments = defaultdict(set)
    for path in paths:
        text = path.read_text(encoding="utf-8")
        source = rel(path)
        for call in MESSAGE_CALL.finditer(text):
            arguments = call_arguments(text, call.end() - 1)
            topic_index = 0 if call.group(1) == "process.listen" else 1
            if len(arguments) <= topic_index:
                continue
            topic_expression = arguments[topic_index]
            literal = re.fullmatch(r"([\"'])(bee(?:\.[A-Za-z0-9_.-]+)+)\1", topic_expression)
            if literal:
                direct[literal.group(2)].add(source)
            used_symbols.update(LUA_NAME.findall(topic_expression))
        for match in STRING_ASSIGNMENT.finditer(text):
            symbol = match.group(1).rsplit(".", 1)[-1]
            assignments[symbol].add((match.group(3), source))
    topics = defaultdict(set)
    for topic, sources in direct.items():
        topics[topic].update(sources)
    for symbol, declarations in assignments.items():
        if symbol in used_symbols or "TOPIC" in symbol:
            for topic, source in declarations:
                if TOPIC_VALUE.fullmatch(topic):
                    topics[topic].add(source)
    return topics


def make_target_names():
    names = set()
    for line in (ROOT / "Makefile").read_text(encoding="utf-8").splitlines():
        if line.startswith("\t") or ":" not in line:
            continue
        left = line.split(":", 1)[0]
        for token in left.split():
            if re.fullmatch(r"[A-Za-z0-9_.-]+", token):
                names.add(token)
    return names


def handoff_evidence():
    path = ROOT / "docs/development/process-handoff.md"
    text = path.read_text(encoding="utf-8")
    targets = sorted(set(HANDOFF_TARGET.findall(text)))
    defined = make_target_names()
    missing = [target for target in targets if target not in defined]
    if missing:
        raise ValueError("process handoff acceptance targets are missing from Makefile: " + ", ".join(missing))
    proposals = PROPOSAL_EVIDENCE.findall(text)
    if not proposals:
        raise ValueError("process-handoff.md no longer states the proposed Hive handoff boundary")
    return {
        "source": rel(path),
        "acceptance_targets": [{"make_target": target, "defined": True} for target in targets],
        "proposal_evidence": proposals,
    }


def nearest_namespace(path, index_documents):
    for parent in path.parents:
        index = parent / "_index.yaml"
        if index in index_documents:
            return index_documents[index]["namespace"]
    return ""


def build_inventory():
    paths = source_indexes()
    index_documents = {path: read_yaml(path) for path in paths}
    module_roots = {}
    for path, document in index_documents.items():
        if path.parent.name == "src" and path.parent.parent.parent.name == "modules":
            module_roots[path.parent] = document.get("namespace")
    if not (ROOT / "src/_index.yaml") in index_documents:
        raise ValueError("src/_index.yaml is missing")

    namespaces = []
    entries = {}
    requirements = []
    stores = []
    persisted_ids = set()
    native_ids = set()
    for path in paths:
        document = index_documents[path]
        namespace = document.get("namespace")
        if not isinstance(namespace, str) or not namespace:
            raise ValueError(f"missing namespace in {rel(path)}")
        expected_namespace = source_namespace(path, module_roots)
        namespaces.append({
            "namespace": namespace,
            "source": rel(path),
            "path_namespace": expected_namespace,
            "path_matches_namespace": namespace == expected_namespace,
            "namespace_has_underscore": any("_" in part for part in namespace.split(".")),
        })
        values = document.get("entries", []) or []
        if not isinstance(values, list):
            raise ValueError(f"entries must be a list in {rel(path)}")
        for entry in values:
            if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                raise ValueError(f"invalid entry in {rel(path)}")
            entry_id = f"{namespace}:{entry['name']}"
            kind = entry.get("kind", "")
            if entry_id in entries:
                raise ValueError(f"duplicate registry id {entry_id} in {rel(path)}")
            entries[entry_id] = {"id": entry_id, "kind": kind, "source": rel(path)}
            if kind in PERSISTED_KINDS:
                persisted_ids.add(entry_id)
            if kind == "ns.requirement":
                targets = entry.get("targets", []) or []
                if not isinstance(targets, list):
                    raise ValueError(f"requirement targets must be a list for {entry_id}")
                defaults = sorted({
                    value for value in iter_strings(entry.get("default"))
                    if REGISTRY_ID.fullmatch(value)
                })
                requirements.append({
                    "id": entry_id,
                    "source": rel(path),
                    "default_reference_ids": defaults,
                    "targets": [
                        {"entry": target.get("entry", ""), "path": target.get("path", "")}
                        for target in targets if isinstance(target, dict)
                    ],
                })
            if kind in {
                "db.sql.sqlite",
                "env.storage.memory",
                "env.storage.os",
                "env.variable",
                "exec.native",
                "fs.directory",
                "process.host",
                "terminal.host",
            }:
                resource = {"id": entry_id, "kind": kind, "source": rel(path)}
                for field in ("file", "directory", "base", "storage", "variable"):
                    value = entry.get(field)
                    if isinstance(value, str):
                        resource[field] = value
                stores.append(resource)

    native_sources = []
    native_root = ROOT / "native"
    if native_root.is_dir():
        for path in sorted(native_root.rglob("*.go")):
            if path.name.endswith("_test.go"):
                continue
            for entry_id in NATIVE_ID.findall(path.read_text(encoding="utf-8")):
                native_ids.add(entry_id)
                native_sources.append({"id": entry_id, "source": rel(path)})
    persisted_ids.update(native_ids)

    external_entries, external_packages = load_external_proofs(index_documents)
    target_resolutions = []
    for requirement in requirements:
        for target in requirement["targets"]:
            entry_id = target["entry"]
            if not isinstance(entry_id, str) or not entry_id:
                raise ValueError(f"missing target entry for {requirement['id']}")
            resolved_by = check_reference(
                entry_id, entries, native_ids, external_entries,
                f"{requirement['source']} ({requirement['id']})",
            )
            target_resolutions.append({
                "requirement": requirement["id"],
                "target": entry_id,
                "resolved_by": resolved_by,
            })
        for entry_id in requirement["default_reference_ids"]:
            check_reference(
                entry_id, entries, native_ids, external_entries,
                f"{requirement['source']} ({requirement['id']} default)",
            )

    lua_paths = []
    for source_root in source_roots():
        lua_paths.extend(source_root.rglob("*.lua"))
    topic_sources = collect_topics(lua_paths)
    schema_sources = defaultdict(set)
    tables = {}
    for path in sorted(lua_paths):
        text = path.read_text(encoding="utf-8")
        source = rel(path)
        owner = nearest_namespace(path, index_documents)
        if owner.endswith(".migrations"):
            owner = owner[: -len(".migrations")]
        table_matches = [(match, match.group(1)) for match in SQL_TABLE.finditer(text)]
        table_matches.extend((match, match.group(2)) for match in LEDGER_TABLE.finditer(text))
        for match, table in table_matches:
            line = text.count("\n", 0, match.start()) + 1
            key = (table, owner, source, line)
            tables[key] = {
                "table": table,
                "owner_namespace": owner,
                "source": source,
                "line": line,
            }
        for schema in SCHEMA_TAG.findall(text):
            schema_sources[schema].add(source)

    for path in paths:
        text = path.read_text(encoding="utf-8")
        for schema in SCHEMA_TAG.findall(text):
            schema_sources[schema].add(rel(path))

    table_names = sorted({record["table"] for record in tables.values()})
    schema_tags = sorted(schema_sources)
    schema_identities = [f"table:{table}" for table in table_names]
    schema_identities.extend(f"tag:{schema}" for schema in schema_tags)
    topics = sorted(topic_sources)
    budget = current_budget()
    root_lines = root_lua_line_count()
    if root_lines > budget:
        raise ValueError(f"src/ has {root_lines} Lua lines, above the {budget} line budget")

    alignment_mismatches = [item for item in namespaces if not item["path_matches_namespace"]]
    return {
        "schema": 1,
        "summary": {
            "namespace_count": len(namespaces),
            "entry_count": len(entries),
            "requirement_count": len(requirements),
            "requirement_target_count": len(target_resolutions),
            "dangling_requirement_target_count": 0,
            "persisted_id_count": len(persisted_ids),
            "topic_count": len(topics),
            "owned_store_count": len(stores),
            "owned_table_declaration_count": len(tables),
            "schema_tag_count": len(schema_tags),
            "native_known_id_count": len(native_ids),
            "namespace_path_mismatch_count": len(alignment_mismatches),
            "namespace_underscore_count": sum(1 for item in namespaces if item["namespace_has_underscore"]),
            "root_src_lua_lines": root_lines,
            "root_src_lua_budget": budget,
        },
        "namespaces": sorted(namespaces, key=lambda item: item["namespace"]),
        "entries": sorted(entries.values(), key=lambda item: item["id"]),
        "requirements": sorted(requirements, key=lambda item: item["id"]),
        "requirement_target_resolutions": sorted(
            target_resolutions, key=lambda item: (item["requirement"], item["target"])
        ),
        "native_known_ids": sorted(native_sources, key=lambda item: (item["id"], item["source"])),
        "owned_stores": sorted(stores, key=lambda item: item["id"]),
        "owned_tables": sorted(tables.values(), key=lambda item: (item["table"], item["source"], item["line"])),
        "schema_tags": [
            {"tag": schema, "sources": sorted(schema_sources[schema])}
            for schema in schema_tags
        ],
        "topics": [
            {"topic": topic, "sources": sorted(topic_sources[topic])}
            for topic in topics
        ],
        "external_dependency_proofs": external_packages,
        "handoff": handoff_evidence(),
    }, {
        "ids": sorted(persisted_ids),
        "topics": topics,
        "schemas": sorted(schema_identities),
    }


def migration_map():
    value = read_json(MIGRATIONS_PATH)
    migrations = value.get("migrations")
    if not isinstance(migrations, list):
        raise ValueError(f"{rel(MIGRATIONS_PATH)} must contain a migrations list")
    grouped = defaultdict(dict)
    for item in migrations:
        if not isinstance(item, dict):
            raise ValueError("migration map entries must be objects")
        category = item.get("category")
        old = item.get("from")
        new = item.get("to")
        migration = item.get("migration")
        reason = item.get("reason")
        if category not in {"ids", "topics", "schemas"}:
            raise ValueError("migration map category must be ids, topics, or schemas")
        if not isinstance(old, str) or not old:
            raise ValueError("migration map from value must be a nonempty string")
        if new is not None and (not isinstance(new, str) or not new):
            raise ValueError("migration map to value must be a nonempty string or null")
        if migration not in {f"M{index}" for index in range(8)}:
            raise ValueError("migration map must name one plan migration M0-M7")
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("migration map entries require a reason")
        if old in grouped[category]:
            raise ValueError(f"duplicate migration map source: {category}:{old}")
        grouped[category][old] = new
    return grouped


def validate_migration_chain(category, old, mappings, current):
    visited = set()
    value = old
    while value not in visited:
        visited.add(value)
        if value in current:
            return True
        if value not in mappings[category]:
            return False
        value = mappings[category][value]
        if value is None:
            return True
    return False


def check_identity_compatibility(previous, current, migrations):
    if not isinstance(previous, dict):
        raise ValueError("identity baseline must be a JSON object")
    for category in ("ids", "topics", "schemas"):
        old_values = set(previous.get(category, []))
        new_values = set(current.get(category, []))
        missing = sorted(old_values - new_values)
        unapproved = [
            value for value in missing
            if not validate_migration_chain(category, value, migrations, new_values)
        ]
        if unapproved:
            raise ValueError(
                f"{category} disappeared or changed without a migration map entry: "
                + ", ".join(unapproved[:20])
            )
    for category, mapping in migrations.items():
        current_values = set(current.get(category, []))
        for old in mapping:
            if not validate_migration_chain(category, old, migrations, current_values):
                raise ValueError(f"migration map chain for {category}:{old} has no current destination")


def check_inventory():
    inventory, identities = build_inventory()
    migrations = migration_map()
    if IDENTITIES_PATH.is_file():
        baseline = read_json(IDENTITIES_PATH)
        check_identity_compatibility(baseline, identities, migrations)
    else:
        raise ValueError(f"missing identity baseline: run make component-inventory")
    expected = json.dumps(inventory, indent=2, sort_keys=True) + "\n"
    if not INVENTORY_PATH.is_file() or INVENTORY_PATH.read_text(encoding="utf-8") != expected:
        raise ValueError(f"{rel(INVENTORY_PATH)} is stale; run make component-inventory")
    summary = inventory["summary"]
    print(
        "component inventory OK: "
        f"{summary['namespace_count']} namespaces, {summary['entry_count']} entries, "
        f"{summary['requirement_target_count']} resolved targets, "
        f"{summary['persisted_id_count']} persisted IDs, {summary['topic_count']} topics, "
        f"src/ {summary['root_src_lua_lines']}/{summary['root_src_lua_budget']} Lua lines"
    )


def write_inventory():
    inventory, identities = build_inventory()
    migrations = migration_map()
    if IDENTITIES_PATH.is_file():
        previous = read_json(IDENTITIES_PATH)
        check_identity_compatibility(previous, identities, migrations)
    write_json(IDENTITIES_PATH, identities)
    write_json(INVENTORY_PATH, inventory)
    summary = inventory["summary"]
    print(
        "wrote component inventory: "
        f"{summary['namespace_count']} namespaces, {summary['entry_count']} entries, "
        f"{summary['requirement_target_count']} resolved targets, "
        f"{summary['persisted_id_count']} persisted IDs, {summary['topic_count']} topics, "
        f"src/ {summary['root_src_lua_lines']}/{summary['root_src_lua_budget']} Lua lines"
    )


def budget_only():
    budget = current_budget()
    lines = root_lua_line_count()
    if lines > budget:
        raise ValueError(f"src/ has {lines} Lua lines, above the {budget} line budget")
    print(f"root src Lua budget OK: {lines}/{budget} lines")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--write", action="store_true")
    group.add_argument("--budget-only", action="store_true")
    args = parser.parse_args()
    try:
        if args.budget_only:
            budget_only()
        elif args.write:
            write_inventory()
        else:
            check_inventory()
    except ValueError as error:
        print(f"component inventory: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
