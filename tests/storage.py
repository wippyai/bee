"""Workspace storage migration and generation-CAS acceptance checks."""
from pathlib import Path
import os
import shutil
import sqlite3
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()

PROBE = r'''local storage = require("store")

local function main()
    local left, left_error = storage.open()
    if not left then error(tostring(left_error)) end
    local right, right_error = storage.open()
    if not right then error(tostring(right_error)) end
    if left.load ~= nil or left.save ~= nil then error("legacy storage aliases remain") end

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
    environment = {**os.environ, "BEE_WORKSPACE_DB": str(folder / "workspace.db")}
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
            assert len(migration) == 1 and migration[0][0] == 1
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
                "VALUES (2, 'future_schema', 'future', 'now')"
            )
            connection.commit()
        assert "newer than this Bee build" in run_probe(project, folder, expect_success=False)
        with sqlite3.connect(database) as connection:
            connection.execute("DELETE FROM workspace_schema_migrations WHERE id = 2")
            connection.commit()
        run_probe(project, folder)

    print("Storage: WAL, migration ledger integrity/newer-version rejection, generation CAS, close behavior")


if __name__ == "__main__":
    main()
