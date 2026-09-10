"""Workspace storage migration and generation-CAS acceptance checks."""
from workspace import database_environment
from pathlib import Path
import hashlib
import re
import os
import shutil
import sqlite3
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()

PROBE = r'''local storage = require("store")

local function main()
    local left, left_error = storage.open()
    if not left then error(tostring(left_error)) end
    local right, right_error = storage.open()
    if not right then error(tostring(right_error)) end
    if left.load ~= nil or left.save ~= nil then error("legacy storage aliases remain") end

    local identity = assert(left:identity())
    assert(#identity == 32 and not identity:find("[^0-9a-f]"))
    assert(identity == assert(right:identity()), "Handles disagree on workspace identity")
    local baseline, baseline_error = left:read()
    if baseline_error then error(tostring(baseline_error)) end
    if not baseline then
        local seeded, seed_error = left:write('{"version":1,"probe":"seed"}')
        if not seeded then error(tostring(seed_error)) end
        baseline = assert(left:read())
    end

    -- Both handles observed the same generation before this commit. The
    -- second handle must not overwrite the first handle's newer value.
    local committed, commit_error = left:write('{"version":1,"probe":"left"}')
    if not committed then error(tostring(commit_error)) end
    local stale, stale_error = right:write('{"version":1,"probe":"stale"}')
    if stale or not stale_error or not tostring(stale_error):find("changed") then
        error("stale handle write was accepted: " .. tostring(stale_error))
    end
    local current, current_error = right:read()
    if current_error or current ~= '{"version":1,"probe":"left"}' then
        error(tostring(current_error or current))
    end
    local right_ok, right_write_error = right:write('{"version":1,"probe":"right"}')
    if not right_ok then error(tostring(right_write_error)) end

    -- The first handle is stale again after the right handle's commit.
    local stale_again, stale_again_error = left:write('{"version":1,"probe":"stale-again"}')
    if stale_again or not stale_again_error or not tostring(stale_again_error):find("changed") then
        error("second stale handle write was accepted: " .. tostring(stale_again_error))
    end
    local refreshed, refresh_error = left:read()
    if refresh_error or refreshed ~= '{"version":1,"probe":"right"}' then
        error(tostring(refresh_error or refreshed))
    end
    local left_ok, left_write_error = left:write('{"version":1,"probe":"final"}')
    if not left_ok then error(tostring(left_write_error)) end

    local closed, close_error = left:close()
    if not closed then error(tostring(close_error)) end
    local closed_identity, closed_identity_error = left:identity()
    assert(not closed_identity and closed_identity_error)
    local closed_read, closed_read_error = left:read()
    if closed_read or not closed_read_error or not tostring(closed_read_error):find("closed") then
        error("closed store remained readable")
    end
    local right_closed, right_close_error = right:close()
    if not right_closed then error(tostring(right_close_error)) end
end

return {main = main}
'''


def run_probe(project, folder, expect_success=True):
    environment = database_environment(folder)
    result = subprocess.run(
        [str(RUNTIME), "run", "storage-probe", "--set", f"registry.history_path={folder / 'registry.db'}"],
        cwd=project,
        env=environment,
        text=True,
        capture_output=True,
        timeout=30,
    )
    output = result.stdout + result.stderr
    if expect_success:
        assert result.returncode == 0, output
    else:
        assert result.returncode != 0, output
    return output


def main():
    with tempfile.TemporaryDirectory(prefix="bee-storage-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copy2(ROOT / ".wippy.yaml", project / ".wippy.yaml")
        shutil.copy2(ROOT / "wippy.lock", project / "wippy.lock")

        probe = project / "src/storage_probe"
        probe.mkdir()
        (probe / "main.lua").write_text(PROBE)
        (probe / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0",
            "namespace": "bee.storage_probe",
            "entries": [{
                "name": "main",
                "kind": "process.lua",
                "source": "file://main.lua",
                "method": "main",
                "modules": ["process"],
                "imports": {"store": "bee.storage:store"},
                "meta": {"command": {"name": "storage-probe", "short": "storage probe"}},
                "security": {"policies": ["bee:workspace_storage_policy"]},
            }],
        }, sort_keys=False))

        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        run_probe(project, folder)
        assert (folder / "registry.db").exists()

        database = folder / "workspace.db"
        with sqlite3.connect(database) as connection:
            assert connection.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
            migration = connection.execute(
                "SELECT id, name, checksum FROM workspace_schema_migrations"
            ).fetchall()
            assert len(migration) == 2 and migration[0][0] == 1 and migration[1][0] == 2
            checksum = migration[0][2]
            state = connection.execute(
                "SELECT generation, value FROM workspace_state WHERE singleton = 1"
            ).fetchone()
            assert state[0] >= 3
            assert state[1] == '{"version":1,"probe":"final"}'

        with sqlite3.connect(database) as connection:
            connection.execute(
                "UPDATE workspace_schema_migrations SET checksum = ? WHERE id = 1",
                ("tampered",),
            )
            connection.commit()
        assert "checksum changed" in run_probe(project, folder, expect_success=False)
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT value FROM workspace_state WHERE singleton = 1"
            ).fetchone()[0] == '{"version":1,"probe":"final"}'
            connection.execute(
                "UPDATE workspace_schema_migrations SET checksum = ? WHERE id = 1",
                (checksum,),
            )
            connection.commit()

        with sqlite3.connect(database) as connection:
            connection.execute(
                "INSERT INTO workspace_schema_migrations (id, name, checksum, applied_at) "
                "VALUES (3, 'future_schema', 'future', 'now')"
            )
            connection.commit()
        assert "newer than this Bee build" in run_probe(project, folder, expect_success=False)
        with sqlite3.connect(database) as connection:
            connection.execute("DELETE FROM workspace_schema_migrations WHERE id = 3")
            connection.commit()
        run_probe(project, folder)

        def identity(path):
            with sqlite3.connect(path) as db:
                return db.execute("SELECT workspace_id FROM workspace_identity WHERE singleton=1").fetchone()[0]

        original_id = identity(database)
        run_probe(project, folder)
        assert identity(database) == original_id, "Reopen changed workspace identity"
        moved = folder / "relocated"
        moved.mkdir()
        with sqlite3.connect(database) as db, sqlite3.connect(moved / "workspace.db") as target:
            db.backup(target)
        run_probe(project, moved)
        assert identity(moved / "workspace.db") == original_id, "Backup/relocation changed identity"
        fresh = folder / "fresh"
        fresh.mkdir()
        run_probe(project, fresh)
        assert identity(fresh / "workspace.db") != original_id, "Fresh workspaces share identity"

        # Upgrade a real migration-1 database. The old SQL/checksum must stay exact.
        legacy = folder / "legacy"
        legacy.mkdir()
        sql = re.search(r"local STATE_TABLE_SQL = \[\[(.*?)\]\]", (ROOT / "src/core/storage/store.lua").read_text(), re.S).group(1)
        # Lua long strings discard the initial newline.
        sql = sql.removeprefix("\n")
        digest = hashlib.sha256(("workspace_state_v1\n" + sql).encode()).hexdigest()
        assert digest == checksum == "c489523d14fa75467dd136391807da471970843d6faaabc5c930092e40af4da2", "Migration 1 checksum changed"
        with sqlite3.connect(legacy / "workspace.db") as db:
            db.execute(sql)
            db.execute("CREATE TABLE workspace_schema_migrations (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)")
            db.execute("INSERT INTO workspace_schema_migrations VALUES (1, 'workspace_state_v1', ?, 'before')", (checksum,))
            db.execute("INSERT INTO workspace_state VALUES (1, 1, 7, ?, 'before')", ('{"version":1,"probe":"legacy"}',))
        # Open only: prove migration leaves the envelope and generation untouched.
        (probe / "main.lua").write_text('local storage = require("store")\nlocal function main() local s = assert(storage.open()); assert(s:identity()); s:close() end\nreturn {main = main}\n')
        store_file = project / "src/core/storage/store.lua"
        healthy_store = store_file.read_text()
        seed = "VALUES (1, lower(hex(randomblob(16))))"
        assert healthy_store.count(seed) == 1
        store_file.write_text(healthy_store.replace(seed, seed + ";\nSELECT * FROM missing_identity_seed_source"))
        assert "apply workspace migration" in run_probe(project, legacy, expect_success=False)
        with sqlite3.connect(legacy / "workspace.db") as db:
            assert db.execute("SELECT count(*) FROM sqlite_master WHERE name='workspace_identity'").fetchone()[0] == 0
            assert db.execute("SELECT count(*) FROM workspace_schema_migrations").fetchone()[0] == 1
            assert db.execute("SELECT generation, value FROM workspace_state").fetchone() == (7, '{"version":1,"probe":"legacy"}')
        store_file.write_text(healthy_store)
        run_probe(project, legacy)
        with sqlite3.connect(legacy / "workspace.db") as db:
            assert db.execute("SELECT generation, value FROM workspace_state").fetchone() == (7, '{"version":1,"probe":"legacy"}')
            assert db.execute("SELECT checksum FROM workspace_schema_migrations WHERE id=1").fetchone()[0] == checksum
        assert len(identity(legacy / "workspace.db")) == 32

        # An applied identity migration cannot silently mint another ID.
        with sqlite3.connect(database) as db:
            db.execute("DELETE FROM workspace_identity")
        assert "identity row is corrupt" in run_probe(project, folder, expect_success=False)
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT count(*) FROM workspace_identity").fetchone()[0] == 0
            db.execute("PRAGMA ignore_check_constraints = ON")
            db.execute("INSERT INTO workspace_identity VALUES (1, 'malformed')")
        assert "identity is invalid" in run_probe(project, folder, expect_success=False)

    print("Storage: WAL, migration ledger integrity/newer-version rejection, generation CAS, close behavior, stable identity, legacy upgrade/rollback, relocation, fresh identity and corrupt identity denial")


def client_storage():
    """Native Lua owns the assertions; these files simulate process/DB failures."""
    with tempfile.TemporaryDirectory(prefix="bee-client-storage-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/client_storage", project / "src/client_storage_probe")
        host = project / "src/_index.yaml"
        configuration = yaml.safe_load(host.read_text())
        next(e for e in configuration["entries"] if e["name"] == "client_db")["file"] = "${env:bee:client_db_path}"
        configuration["entries"] += [
            {"name": "client_db_path", "kind": "env.variable", "storage": "bee:workspace_environment",
             "variable": "BEE_CLIENT_DB", "default": str(root / "build-client.db"), "readonly": True},
        ]
        host.write_text(yaml.safe_dump(configuration, sort_keys=False))
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = root / "client-storage.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)

        def probe(folder, mode, packed=False, failure=None, command="client-storage-probe"):
            folder.mkdir(exist_ok=True)
            args = [str(RUNTIME), "--console", "run"] + ([str(pack)] if packed else [])
            args += [command, mode, "--set", f"registry.history_path={folder / 'registry.db'}"]
            result = subprocess.run(args, cwd=folder if packed else project, capture_output=True, text=True, timeout=30,
                                    env=database_environment(folder, BEE_CLIENT_DB=str(folder / "client.db")))
            output = result.stdout + result.stderr
            if failure is None:
                assert result.returncode == 0, output
            else:
                assert result.returncode != 0 and failure in output, output

        # Seed the actual v1 schema and preserve a populated default layout.
        # The fixed checksum prevents this proof from accepting edits to v1 SQL.
        v1_sql = re.search(r"local SCHEMA = \[\[(.*?)\]\]", (ROOT / "src/core/client/store.lua").read_text(), re.S).group(1).removeprefix("\n")
        v1_checksum = hashlib.sha256(("client_layout_v1\n" + v1_sql).encode()).hexdigest()
        assert v1_checksum == "f35f913f50cfd4b0dbe6c8b448a063f2de35be2c2a469c04b26f7720faa029e6"
        for packed in (False, True):
            folder = root / ("packed" if packed else "source")
            probe(folder, "seed", packed, command="client-storage-bindings")
            probe(folder, "verify", packed, command="client-storage-bindings")
            probe(folder, "verify", packed, command="client-storage-denial")
            probe(folder, "seed", packed)
            database = folder / "client.db"
            with sqlite3.connect(database) as db:
                original = db.execute("SELECT client_id, import_workspace, import_receipt FROM client_state").fetchone()
                assert all(len(value) == 32 for value in original)
                assert db.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
            # Stop after the client commit, before any host-side acknowledgement.
            # Reopen in another process, edit, and retry the original import.
            probe(folder, "edit", packed)
            probe(folder, "verify", packed)
            probe(folder, "desktops", packed)
            probe(folder, "verify_desktops", packed)
            legacy = root / ("v1-packed" if packed else "v1-source")
            legacy.mkdir()
            with sqlite3.connect(database) as current:
                populated = current.execute("SELECT * FROM client_state").fetchone()
            with sqlite3.connect(legacy / "client.db") as old:
                old.executescript(v1_sql)
                old.execute("DELETE FROM client_state")
                old.execute("INSERT INTO client_state VALUES (?, ?, ?, ?, ?, ?)", populated)
                old.execute("CREATE TABLE client_schema_migrations (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL)")
                old.execute("INSERT INTO client_schema_migrations VALUES (1, 'client_layout_v1', ?)", (v1_checksum,))
            probe(legacy, "verify", packed)
            probe(legacy, "desktops", packed)
            probe(legacy, "verify_desktops", packed)
            with sqlite3.connect(legacy / "client.db") as upgraded:
                assert upgraded.execute("SELECT * FROM client_state").fetchone() == populated
                assert upgraded.execute("SELECT checksum FROM client_schema_migrations WHERE id=1").fetchone()[0] == v1_checksum
                assert upgraded.execute("SELECT count(*) FROM client_schema_migrations").fetchone()[0] == 2
            with sqlite3.connect(database) as db:
                assert db.execute("SELECT client_id, import_workspace, import_receipt FROM client_state").fetchone() == original
                ledger = db.execute("SELECT checksum FROM client_schema_migrations WHERE id=1").fetchone()[0]
                db.execute("UPDATE client_schema_migrations SET checksum='changed' WHERE id=1")
            probe(folder, "open", packed, "migration ledger")
            with sqlite3.connect(database) as db:
                db.execute("UPDATE client_schema_migrations SET checksum=? WHERE id=1", (ledger,))
                db.execute("INSERT INTO client_schema_migrations VALUES (3, 'future', 'future')")
            probe(folder, "open", packed, "newer")
            with sqlite3.connect(database) as db:
                db.execute("DELETE FROM client_schema_migrations WHERE id=3")
                saved_value = db.execute("SELECT value FROM client_state").fetchone()[0]
                db.execute("UPDATE client_state SET value='{\"version\":2}'")
            probe(folder, "open", packed, "Unsupported or corrupt client layout")
            with sqlite3.connect(database) as db:
                db.execute("UPDATE client_state SET value=?", (saved_value,))
                db.execute("DELETE FROM client_state")
            probe(folder, "open", packed, "identity row is corrupt")

            fresh = root / ("existing-pack" if packed else "existing-source")
            probe(fresh, "existing", packed)

            interrupted = root / ("interrupted-pack" if packed else "interrupted-source")
            probe(interrupted, "open", packed)
            with sqlite3.connect(interrupted / "client.db") as db:
                db.execute("CREATE TRIGGER fail_import BEFORE UPDATE ON client_state BEGIN SELECT RAISE(ABORT, 'injected import failure'); END")
            probe(interrupted, "seed", packed, "injected import failure")
            with sqlite3.connect(interrupted / "client.db") as db:
                assert db.execute("SELECT generation, value, import_receipt FROM client_state").fetchone() == (0, None, "")
                db.execute("DROP TRIGGER fail_import")
            probe(interrupted, "seed", packed)
        # A failed first migration must not leave a ledger claiming success or a
        # half-created identity. Only this disposable staged source is changed.
        staged_store = project / "src/core/client/store.lua"
        healthy = staged_store.read_text()
        staged_store.write_text(healthy.replace("INSERT INTO client_state", "INVALID MIGRATION;\nINSERT INTO client_state", 1))
        failed_migration = root / "failed-migration"
        probe(failed_migration, "open", failure="syntax error")
        with sqlite3.connect(failed_migration / "client.db") as db:
            assert db.execute("SELECT count(*) FROM sqlite_master WHERE name IN ('client_state', 'client_schema_migrations')").fetchone()[0] == 0
        staged_store.write_text(healthy)
        probe(failed_migration, "seed")
    print("Client storage source/pack: independent client/workspace bindings, native grant/boundary denial, stable identity, qualified layout, generation CAS, atomic import/retry after restart, existing-layout protection, ledger and corruption denial; independent desktop isolation/CAS/capacity/restart and populated-v1 upgrade")


if __name__ == "__main__":
    main()
    client_storage()
