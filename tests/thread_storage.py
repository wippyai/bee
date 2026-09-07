"""Production journal: native caller scope, replay, conflicts and checked migrations."""
from pathlib import Path
import os
import shutil
import sqlite3
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME

PROBE = r'''
local journal = require("journal")
local contract = require("contract")
local sql = require("sql")
local process = require("process")
local function main(run_name: string?)
    local direct, direct_error = sql.get("bee.threads:db")
    assert(direct == nil and direct_error ~= nil, "Caller gained SQL authority")
    local log = assert(journal.open("acceptance"))
    if run_name == "parallel" then
        local events = assert(process.events())
        for i = 1, 4 do
            assert(process.spawn_monitored("bee.journal_probe:main", "bee.test_status:workers", "parallel-" .. tostring(i)))
        end
        local finished = 0
        while finished < 4 do
            local event = assert(events:receive())
            if event.kind == process.event.EXIT then
                if event.result and event.result.error then error(tostring(event.result.error)) end
                finished = finished + 1
            end
        end
        return
    end
    if run_name then
        assert(log:claim(run_name))
        for i = 1, 10 do assert(log:append(run_name, tostring(i), "concurrent", "{}")) end
        return
    end
    local claim, claim_error = log:claim("run")
    assert(claim, claim_error or "Claim failed")
    local duplicate = assert(log:claim("run"))
    assert(not duplicate.created, "Duplicate claim created a run")
    for i = 1, 65 do
        local result, err = log:append("run", "key-" .. tostring(i), "check", "{}")
        assert(result, err or "Append failed")
        assert(result.seq == i, "Sequence changed across retry")
    end
    local conflict, conflict_error = log:append("run", "key-1", "check", '{"different":true}')
    assert(conflict == nil and conflict_error ~= nil, "Conflicting retry accepted")
    local invalid, invalid_error = log:append("run", "invalid", "check", "not-json")
    assert(invalid == nil and invalid_error ~= nil, "Malformed JSON accepted")
    local first = assert(log:read_after(0))
    local second = assert(log:read_after(64))
    assert(#first.events == 64 and #second.events == 1 and second.events[1].seq == 65, "Replay page boundary")
    local bad_cursor, cursor_error = log:read_after(-1)
    assert(bad_cursor == nil and cursor_error ~= nil, "Invalid cursor accepted")
    local binding = assert(contract.open("bee.threads:local"))
    local denied, denied_error = binding:read_after({thread = "foreign", after = 0, actor = "foreign-actor"})
    assert(denied_error == nil and type(denied) == "table" and denied.ok == false, "Payload actor bypassed ownership")
    local after, after_error = sql.get("bee.threads:db")
    assert(after == nil and after_error ~= nil, "Function policy leaked into caller")
end
return {main = main}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="bee-thread-storage-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "src", folder / "src")
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, folder / name)
        probe = folder / "src/probe"
        probe.mkdir()
        (probe / "main.lua").write_text(PROBE)
        (probe / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee.journal_probe", "entries": [{
                "name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main",
                "modules": ["sql", "contract", "process"], "imports": {"journal": "bee.threads:client"},
                "meta": {"command": {"name": "journal-probe", "security": {"actor": {"id": "journal-test"}}}},
                "security": {"policies": ["bee:thread_read_client_policy", "bee:thread_write_client_policy", "bee.journal_probe:spawn_policy"]},
            }, {"name": "spawn_policy", "kind": "security.policy", "policy": {
                "actions": ["process.spawn", "process.spawn.monitored", "process.host", "process.monitor"],
                "resources": "*", "effect": "allow"}}]}))
        database = folder / "threads.db"
        environment = {**os.environ, "BEE_THREADS_DB": str(database), "BEE_WORKSPACE_DB": str(folder / "workspace.db")}

        def run(ok=True, run_name=None):
            registry = folder / f"registry-{run_name or 'main'}.db"
            arguments = [run_name] if run_name else []
            result = subprocess.run([str(RUNTIME), "run", "journal-probe", *arguments, "--set", f"registry.history_path={registry}"],
                                    cwd=folder, env=environment, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert (result.returncode == 0) == ok, output
            return output

        subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True)
        run()
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO bee_threads VALUES ('foreign', 'foreign-actor', 'now')")
            checksum = db.execute("SELECT checksum FROM bee_thread_schema_migrations").fetchone()[0]
        run()
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT COUNT(*) FROM bee_thread_events").fetchone()[0] == 65
            db.execute("UPDATE bee_thread_schema_migrations SET checksum='tampered'")
        assert "checksum changed" in run(False)
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT COUNT(*) FROM bee_thread_events").fetchone()[0] == 65
            db.execute("UPDATE bee_thread_schema_migrations SET checksum=?", (checksum,))
            db.execute("INSERT INTO bee_thread_schema_migrations VALUES (2, 'future', 'future', 'now')")
        assert "schema is newer" in run(False)
        with sqlite3.connect(database) as db:
            db.execute("DELETE FROM bee_thread_schema_migrations WHERE id=2")
        run(run_name="parallel")
        with sqlite3.connect(database) as db:
            count, distinct_count, maximum = db.execute("SELECT COUNT(*), COUNT(DISTINCT sequence), MAX(sequence) FROM bee_thread_events").fetchone()
            assert (count, distinct_count, maximum) == (105, 105, 105)

    print("Production journal: native caller SQL denial, actor spoof denial, 64-row replay, cold idempotency/conflict, invalid JSON/cursor, migration integrity, concurrent writers")


if __name__ == "__main__":
    main()
