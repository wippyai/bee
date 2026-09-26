"""Production threads: native caller scope, checked migrations and durable subscriptions."""
from workspace import database_environment
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME

# This probe proves the contract functions keep SQL authority to themselves,
# then exercises the durable subscription lifecycle: the cursor survives a
# close and restart, a resume fences the old lease, and a forgotten
# subscription stays absent after restart.
PROBE = r'''
local contract = require("contract")
local sql = require("sql")
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
    assert(type(reply) == "table" and reply.ok == true, method .. " failed: " .. tostring(reply.error and reply.error.code) .. "/" .. tostring(reply.error and reply.error.message))
    return reply.value :: {[string]: unknown}
end
local function main(phase: string?, sub: string?, cursor: string?)
    local before, before_error = sql.get("bee.threads:db")
    assert(before == nil and before_error ~= nil, "Caller gained SQL authority")
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
    local after, after_error = sql.get("bee.threads:db")
    assert(after == nil and after_error ~= nil, "Function policy leaked into caller")
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
        probe = folder / "src/lifecycleprobe"
        probe.mkdir()
        (probe / "main.lua").write_text(PROBE)
        (probe / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee.lifecycleprobe", "entries": [{
                "name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main",
                "modules": ["contract", "sql", "uuid", "io"],
                "imports": {},
                "meta": {"command": {"name": "lifecycle-probe", "security": {"actor": {"id": "lifecycle-test"}}}},
                "security": {"policies": ["bee.security.threads:thread_authority_client_policy", "bee.security.threads:thread_delivery_client_policy", "bee.lifecycleprobe:create_policy"]},
            }, {"name": "create_policy", "kind": "security.policy", "policy": {
                "actions": ["bee.threads.create"], "resources": ["lifecycle-thread"], "effect": "allow"}}]}))
        subprocess.run([str(RUNTIME), "lint", "--ns", "bee.lifecycleprobe"], cwd=folder, check=True)
        database = folder / "lifecycle.db"
        environment = database_environment(folder, BEE_THREADS_DB=str(database))

        def run(*arguments, ok=True):
            registry = folder / f"registry-{arguments[0]}.db"
            result = subprocess.run([str(RUNTIME), "run", "lifecycle-probe", *arguments, "--set", f"registry.history_path={registry}"],
                                    cwd=folder, env=environment, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert (result.returncode == 0) == ok, output
            return output

        prepared = run("prepare")
        fields = dict(pair.split("=", 1) for pair in prepared.split() if "=" in pair)
        subscription_id, cursor = fields["SUB"], fields["CURSOR"]
        with sqlite3.connect(database) as db:
            records = db.execute("SELECT COUNT(*) FROM bee_thread_records").fetchone()[0]
            checksum = db.execute("SELECT checksum FROM bee_thread_schema_migrations WHERE id=1").fetchone()[0]
            db.execute("UPDATE bee_thread_schema_migrations SET checksum='tampered' WHERE id=1")
        assert "checksum changed" in run("resume", subscription_id, cursor, ok=False)
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT COUNT(*) FROM bee_thread_records").fetchone()[0] == records
            db.execute("UPDATE bee_thread_schema_migrations SET checksum=? WHERE id=1", (checksum,))
            future = db.execute("SELECT MAX(id) + 1 FROM bee_thread_schema_migrations").fetchone()[0]
            db.execute("INSERT INTO bee_thread_schema_migrations VALUES (?, 'future', 'future', 'now')", (future,))
        assert "schema is newer" in run("resume", subscription_id, cursor, ok=False)
        with sqlite3.connect(database) as db:
            db.execute("DELETE FROM bee_thread_schema_migrations WHERE id=?", (future,))
        assert "RESUMED" in run("resume", subscription_id, cursor)
        assert "FORGOTTEN" in run("forget", subscription_id)
        assert "ABSENT" in run("verify", subscription_id)

    print("Production threads: caller SQL denial, migration checksum/future-ledger fail-closed with data intact; subscription-lifecycle restart (cursor preserved, lease fenced, forgotten absent)")


if __name__ == "__main__":
    main()
