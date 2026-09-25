"""Production journal: native caller scope, replay, conflicts and checked migrations."""
from workspace import database_environment
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
            assert(process.spawn_monitored("bee.journal_probe:main", "bee:workers", "parallel-" .. tostring(i)))
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



# This subscription-lifecycle restart probe proves the durable cursor
# survives a close and restart, a resume fences the old lease, and a forgotten
# subscription stays absent after restart.
LIFECYCLE_PROBE = r'''
local contract = require("contract")
local uuid = require("uuid")
local io = require("io")
local THREAD = "lifecycle-thread"
local function key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
local function call(binding: any, method: string, request: {[string]: unknown}): {[string]: unknown}
    local reply = assert(binding[method](binding, request))
    assert(type(reply) == "table" and reply.ok == true, method .. " failed: " .. tostring(type(reply) == "table" and reply.error and reply.error.code))
    return reply.value :: {[string]: unknown}
end
local function main(phase: string?, sub: string?, cursor: string?)
    local authority = assert(contract.open("bee.threads:authority_local"))
    local delivery = assert(contract.open("bee.threads:delivery_local"))
    if phase == "prepare" then
        call(authority, "create", {thread_id = THREAD, idempotency_key = key(), title = "Lifecycle"})
        for i = 1, 5 do
            call(authority, "record", {thread_id = THREAD, idempotency_key = key(), kind = "message",
                body = {message_id = "m" .. tostring(i), message_kind = "request", recipient_ids = {}, content = {text = "line " .. tostring(i)}}})
        end
        local created = call(delivery, "subscribe", {thread_id = THREAD, idempotency_key = key(), consumer_id = "durable", after_sequence = 0, durability = "durable"})
        local page = call(delivery, "page", {thread_id = THREAD, subscription_id = created.subscription_id})
        call(delivery, "ack_page", {thread_id = THREAD, idempotency_key = key(), subscription_id = created.subscription_id, page_id = page.page_id, scanned_through = page.scanned_through})
        call(delivery, "close_subscription", {thread_id = THREAD, idempotency_key = key(), subscription_id = created.subscription_id})
        io.print("SUB=" .. tostring(created.subscription_id) .. " CURSOR=" .. tostring(page.scanned_through))
    elseif phase == "resume" then
        local expected = math.floor(tonumber(cursor) or -1)
        local resumed = call(delivery, "resume", {thread_id = THREAD, idempotency_key = key(), subscription_id = sub})
        assert(resumed.after_sequence == expected, "cursor not preserved across restart")
        assert(resumed.lease_generation == 2, "resume did not fence the old lease")
        local page = call(delivery, "page", {thread_id = THREAD, subscription_id = sub})
        assert(page.from_sequence == expected, "resumed page did not start at the preserved cursor")
        io.print("RESUMED")
    elseif phase == "forget" then
        call(delivery, "close_subscription", {thread_id = THREAD, idempotency_key = key(), subscription_id = sub})
        call(delivery, "forget_subscription", {thread_id = THREAD, idempotency_key = key(), subscription_id = sub})
        io.print("FORGOTTEN")
    elseif phase == "verify" then
        local reply = assert(delivery:page({thread_id = THREAD, subscription_id = sub}))
        assert(type(reply) == "table" and reply.ok == false and reply.error.code == "NOT_FOUND", "forgotten subscription survived restart")
        io.print("ABSENT")
    end
end
return {main = main}
'''

def main():
    with tempfile.TemporaryDirectory(prefix="bee-thread-storage-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "src", folder / "src")
        shutil.copytree(ROOT / "modules", folder / "modules")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, folder / name)
        probe = folder / "src/probe"
        probe.mkdir()
        (probe / "main.lua").write_text(PROBE)
        (probe / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee.journal_probe", "entries": [{
                "name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main",
                "modules": ["sql", "contract", "process"], "imports": {"journal": "bee.threads:client"},
                "meta": {"command": {"name": "journal-probe", "security": {"actor": {"id": "journal-test"}}}},
                "security": {"policies": ["bee.security.threads:thread_read_client_policy", "bee.security.threads:thread_write_client_policy", "bee.journal_probe:spawn_policy"]},
            }, {"name": "spawn_policy", "kind": "security.policy", "policy": {
                "actions": ["process.spawn", "process.spawn.monitored", "process.host", "process.monitor"],
                "resources": "*", "effect": "allow"}}]}))
        database = folder / "threads.db"
        environment = database_environment(folder, BEE_THREADS_DB=str(database))

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
            checksum = db.execute("SELECT checksum FROM bee_thread_schema_migrations WHERE id=1").fetchone()[0]
        run()
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT COUNT(*) FROM bee_thread_events").fetchone()[0] == 65
            db.execute("UPDATE bee_thread_schema_migrations SET checksum='tampered' WHERE id=1")
        assert "checksum changed" in run(False)
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT COUNT(*) FROM bee_thread_events").fetchone()[0] == 65
            db.execute("UPDATE bee_thread_schema_migrations SET checksum=? WHERE id=1", (checksum,))
            future = db.execute("SELECT MAX(id) + 1 FROM bee_thread_schema_migrations").fetchone()[0]
            db.execute("INSERT INTO bee_thread_schema_migrations VALUES (?, 'future', 'future', 'now')", (future,))
        assert "schema is newer" in run(False)
        with sqlite3.connect(database) as db:
            db.execute("DELETE FROM bee_thread_schema_migrations WHERE id=?", (future,))
        run(run_name="parallel")
        with sqlite3.connect(database) as db:
            count, distinct_count, maximum = db.execute("SELECT COUNT(*), COUNT(DISTINCT sequence), MAX(sequence) FROM bee_thread_events").fetchone()
            assert (count, distinct_count, maximum) == (105, 105, 105)

        # Durable subscription lifecycle across restarts. The command actor
        # can call the contracts and create only this fixture's thread.
        lifecycle = folder / "src/lifecycle_probe"
        lifecycle.mkdir()
        (lifecycle / "main.lua").write_text(LIFECYCLE_PROBE)
        (lifecycle / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee.lifecycle_probe", "entries": [{
                "name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main",
                "modules": ["contract", "uuid", "io"],
                "imports": {},
                "meta": {"command": {"name": "lifecycle-probe", "security": {"actor": {"id": "lifecycle-test"}}}},
                "security": {"policies": ["bee.security.threads:thread_authority_client_policy", "bee.security.threads:thread_delivery_client_policy", "bee.lifecycle_probe:create_policy"]},
            }, {"name": "create_policy", "kind": "security.policy", "policy": {
                "actions": ["bee.threads.create"], "resources": ["lifecycle-thread"], "effect": "allow"}}]}))
        subprocess.run([str(RUNTIME), "lint", "--ns", "bee.lifecycle_probe"], cwd=folder, check=True)
        lifecycle_db = folder / "lifecycle.db"
        lifecycle_env = database_environment(folder, BEE_THREADS_DB=str(lifecycle_db))

        def lifecycle_run(*arguments):
            registry = folder / f"registry-lifecycle-{arguments[0]}.db"
            result = subprocess.run([str(RUNTIME), "run", "lifecycle-probe", *arguments, "--set", f"registry.history_path={registry}"],
                                    cwd=folder, env=lifecycle_env, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            return output

        prepared = lifecycle_run("prepare")
        fields = dict(pair.split("=", 1) for pair in prepared.split() if "=" in pair)
        subscription_id, cursor = fields["SUB"], fields["CURSOR"]
        assert "RESUMED" in lifecycle_run("resume", subscription_id, cursor)
        assert "FORGOTTEN" in lifecycle_run("forget", subscription_id)
        assert "ABSENT" in lifecycle_run("verify", subscription_id)

    print("Production journal: native caller SQL denial, actor spoof denial, 64-row replay, cold idempotency/conflict, invalid JSON/cursor, migration integrity, concurrent writers; subscription-lifecycle restart (cursor preserved, lease fenced, forgotten absent)")


if __name__ == "__main__":
    main()
