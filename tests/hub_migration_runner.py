"""Real SQL/ledger compatibility with the pinned public migration libraries.

The artifact supplies unchanged libraries to a disposable composition, not a
production dependency. Its bootloader and package dependencies are not activated.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ["BEE_RUNTIME"]).resolve()
ARTIFACT_SHA = "55834821cd2832f8582a52e98772810ba3bdfe91d4967262d3d69e6e9c2b2879"
artifact = Path(sys.argv[1]).resolve()
assert hashlib.sha256(artifact.read_bytes()).hexdigest() == ARTIFACT_SHA, "Expected the pinned wippy/migration 0.3.17 artifact"
encoded = subprocess.check_output(
    ["go", "-C", str(ROOT / "native"), "run", "-mod=readonly", "../tests/hub_migration_entries.go", str(artifact)]
)
entries = json.loads(encoded)
selected = {"core", "migration", "registry", "repository", "runner"}
folder = Path(tempfile.mkdtemp(prefix="bee-hub-migration-"))
try:
    shutil.copytree(ROOT / "tests/fixtures/hub_migration_runner", folder / "src")
    for name in (".wippy.yaml", "wippy.lock"):
        shutil.copy2(ROOT / name, folder / name)
    (folder / ".wippy").mkdir()
    (folder / "src/hub").mkdir()
    for name in ("migrations.lua", "migration_runner.lua"):
        shutil.copy2(ROOT / "src/hub" / name, folder / "src/hub" / name)
    libraries = folder / "src/wippy_migration"
    libraries.mkdir()
    projected = []
    for entry in entries:
        identity = entry["ID"]
        name = identity["name"]
        if identity["ns"] != "wippy.migration" or name not in selected:
            continue
        assert entry["Kind"] == "library.lua"
        data = dict(entry["Data"])
        source = data.pop("source")
        assert isinstance(source, str)
        (libraries / f"{name}.lua").write_text(source)
        projected.append({"name": name, "kind": "library.lua", "meta": entry.get("Meta", {}),
                          **data, "source": f"file://{name}.lua"})
    assert {entry["name"] for entry in projected} == selected
    (libraries / "_index.yaml").write_text(yaml.safe_dump(
        {"version": "1.0", "namespace": "wippy.migration", "entries": projected}, sort_keys=False))
    result = subprocess.run([str(RUNTIME), "run", "-x", "probe:run"], cwd=folder,
                            capture_output=True, text=True, timeout=45)
    (folder / "runtime.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, f"Migration probe exited {result.returncode}: {result.stdout}{result.stderr}"
    database = folder / ".wippy/probe.db"
    assert database.is_file(), "Probe did not create its target database"
    with sqlite3.connect(database) as connection:
        rows = {row[0]: tuple(row[1:]) for row in connection.execute("SELECT * FROM probe_acceptance_evidence")}
        changed = (1, 1, 0, 1, 1, 0)
        cleared = (0, 0, 0, 0, 0, 0)
        assert rows == {"public_up": changed, "public_repeat": changed, "public_down": cleared,
                        "binding_up": changed, "binding_down": cleared}, rows
        assert connection.execute("SELECT COUNT(*) FROM _migrations").fetchone()[0] == 0
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert tables == {"_migrations", "probe_acceptance_evidence"}, tables
    negative = subprocess.run([str(RUNTIME), "run", "-x", "probe:negative_run"], cwd=folder,
                              capture_output=True, text=True, timeout=45)
    (folder / "negative-runtime.log").write_text(negative.stdout + negative.stderr)
    assert negative.returncode == 0, f"Negative probe exited {negative.returncode}: {negative.stdout}{negative.stderr}"
    negative_database = folder / ".wippy/negative.db"
    evidence_database = folder / ".wippy/evidence.db"
    assert negative_database.is_file() and evidence_database.is_file(), "Negative probe evidence missing"
    with sqlite3.connect(evidence_database) as connection:
        rows = {row[0]: tuple(row[1:]) for row in connection.execute("SELECT * FROM negative_evidence")}
        expected = {"absent_ledger": ("false", "nil"),
                    "missing_db_grant": ("false", "database grant"),
                    "missing_db_attempt": ("true", "database"),
                    "missing_func_grant": ("false", "function grant"),
                    "missing_func_attempt": ("true", "function grant")}
        assert rows.keys() == expected.keys(), rows
        for phase, (value, problem) in expected.items():
            assert rows[phase][0] == value and problem in rows[phase][1], (phase, rows[phase])
    with sqlite3.connect(negative_database) as connection:
        assert connection.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall() == []
except BaseException:
    print(f"Migration fixture preserved: {folder}", file=sys.stderr)
    raise
else:
    shutil.rmtree(folder)
print("Hub migration runner: public DSL and Bee binding agree on SQLite up/repeat/down; excluded ID stays untouched; absent ledger and denied grants have no schema effects")
