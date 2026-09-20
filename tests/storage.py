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
local assignments = require("assignments")

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

    -- This is the workspace-owned persistence slice. Host admission and the
    -- physical revoke/mount operations remain outside this fixture.
    local transfer = assert(assignments.open(left))
    local existing, existing_error = transfer:get({view_id = "view-one", instance_id = "instance-one"})
    assert(not existing_error)
    if existing then
        assert(existing.assignment.display_id == "display-b" and existing.assignment.revision == 2)
    else
        local initial = assert(transfer:claim({view_id = "view-one", instance_id = "instance-one", display_id = "display-a"}))
        assert(initial.revision == 1)
        assert(assert(transfer:claim({view_id = "view-one", instance_id = "instance-one", display_id = "display-a"})).revision == 1)
        local foreign_claim, foreign_claim_error = transfer:claim({view_id = "view-one", instance_id = "instance-one", display_id = "display-b"})
        assert(not foreign_claim and foreign_claim_error and foreign_claim_error:find("another display"))
        local prepared = assert(transfer:prepare({request_id = "move-one", view_id = "view-one", instance_id = "instance-one", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1}))
        assert(prepared.phase == "prepared")
        local fenced = assert(transfer:get({view_id = "view-one", instance_id = "instance-one"}))
        assert(fenced.assignment.display_id == "display-a" and fenced.intent and fenced.intent.phase == "prepared")
        local prepared_claim, prepared_claim_error = transfer:claim({view_id = "view-one", instance_id = "instance-one", display_id = "display-a"})
        assert(not prepared_claim and prepared_claim_error and prepared_claim_error:find("prepared"))
        local recovery = assert(transfer:reconcile())
        assert(#recovery == 1 and recovery[1].intent and recovery[1].intent.phase == "prepared")
        assert(assert(transfer:prepare({request_id = "move-one", view_id = "view-one", instance_id = "instance-one", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1})).phase == "prepared")
        local conflict, conflict_error = transfer:prepare({request_id = "move-one", view_id = "view-one", instance_id = "instance-one", source_display_id = "display-a", target_display_id = "display-c", expected_revision = 1})
        assert(not conflict and conflict_error and conflict_error:find("conflicts"))
        local concurrent, concurrent_error = transfer:prepare({request_id = "move-two", view_id = "view-one", instance_id = "instance-one", source_display_id = "display-a", target_display_id = "display-c", expected_revision = 1})
        assert(not concurrent and concurrent_error and concurrent_error:find("already prepared"))
        assert(assert(transfer:fail({request_id = "move-one", view_id = "view-one", instance_id = "instance-one", error = "revoke rejected"})).phase == "failed")
        assert(assert(transfer:get({view_id = "view-one", instance_id = "instance-one"})).assignment.display_id == "display-a")
        local stale, stale_error = transfer:prepare({request_id = "move-stale", view_id = "view-one", instance_id = "instance-one", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 2})
        assert(not stale and stale_error and stale_error:find("changed"))
        assert(assert(transfer:prepare({request_id = "move-three", view_id = "view-one", instance_id = "instance-one", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1})).phase == "prepared")
        local committed = assert(transfer:commit({request_id = "move-three", view_id = "view-one", instance_id = "instance-one"}))
        assert(committed.assignment.display_id == "display-b" and committed.assignment.revision == 2 and committed.intent and committed.intent.phase == "committed")
        assert(assert(transfer:commit({request_id = "move-three", view_id = "view-one", instance_id = "instance-one"})).assignment.revision == 2)
        for index = 2, 16 do
            assert(transfer:claim({view_id = "view-" .. tostring(index), instance_id = "instance-" .. tostring(index), display_id = "display-a"}))
        end
        local over_limit, over_limit_error = transfer:claim({view_id = "view-17", instance_id = "instance-17", display_id = "display-a"})
        assert(not over_limit and over_limit_error and over_limit_error:find("capacity"))
        assert(assert(transfer:prepare({request_id = "retire-pending", view_id = "view-2", instance_id = "instance-2", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1})).phase == "prepared")
        local premature_retire, premature_retire_error = transfer:retire({view_id = "view-2", instance_id = "instance-2"})
        assert(not premature_retire and premature_retire_error and premature_retire_error:find("prepared"))
        assert(assert(transfer:fail({request_id = "retire-pending", view_id = "view-2", instance_id = "instance-2", error = "app exited"})).phase == "failed")
        assert(transfer:retire({view_id = "view-2", instance_id = "instance-2"}))
        assert(transfer:claim({view_id = "view-17", instance_id = "instance-17", display_id = "display-a"}))
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

EXHAUSTION_PROBE = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local transfer = assert(assignments.open(workspace))
    local prepared, prepare_error = transfer:prepare({request_id = "revision-overflow", view_id = "view-17", instance_id = "instance-17", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 9007199254740990})
    assert(not prepared and prepare_error and prepare_error:find("exhausted"))
    assert(workspace:close())
end
return {main = main}
'''

ASSIGNMENT_PREPARE = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local transfers = assert(assignments.open(workspace))
    assert(transfers:claim({view_id = "restart-view", instance_id = "restart-instance", display_id = "display-a"}))
    assert(transfers:prepare({request_id = "restart-transfer", view_id = "restart-view", instance_id = "restart-instance", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1}))
    assert(workspace:close())
end
return {main = main}
'''

ASSIGNMENT_PREPARED = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local value = assert(assert(assignments.open(workspace)):get({view_id = "restart-view", instance_id = "restart-instance"}))
    assert(value.assignment.display_id == "display-a" and value.assignment.revision == 1)
    assert(value.intent and value.intent.request_id == "restart-transfer" and value.intent.phase == "prepared")
    assert(workspace:close())
end
return {main = main}
'''

ASSIGNMENT_COMMIT_FAILS = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local committed, commit_error = assert(assignments.open(workspace)):commit({request_id = "restart-transfer", view_id = "restart-view", instance_id = "restart-instance"})
    assert(not committed and commit_error and commit_error:find("forced receipt failure"))
    assert(workspace:close())
end
return {main = main}
'''

ASSIGNMENT_COMMIT = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local committed = assert(assert(assignments.open(workspace)):commit({request_id = "restart-transfer", view_id = "restart-view", instance_id = "restart-instance"}))
    assert(committed.assignment.display_id == "display-b" and committed.assignment.revision == 2 and committed.intent and committed.intent.phase == "committed")
    assert(workspace:close())
end
return {main = main}
'''

ASSIGNMENT_HISTORY = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local transfers = assert(assignments.open(workspace))
    assert(transfers:claim({view_id = "history-view", instance_id = "history-instance", display_id = "display-a"}))
    local source, target, expected = "display-a", "display-b", 1
    for index = 1, 65 do
        local request_id = "history-" .. tostring(index)
        local prepared, prepare_error = transfers:prepare({request_id = request_id, view_id = "history-view", instance_id = "history-instance", source_display_id = source, target_display_id = target, expected_revision = expected})
        assert(prepared, "history " .. tostring(index) .. ": " .. tostring(prepare_error))
        local committed = assert(transfers:commit({request_id = request_id, view_id = "history-view", instance_id = "history-instance"}))
        assert(committed.assignment.revision == expected + 1)
        source = committed.assignment.display_id
        target = source == "display-a" and "display-b" or "display-a"
        expected = committed.assignment.revision
    end
    assert(workspace:close())
end
return {main = main}
'''

ASSIGNMENT_HISTORY_REPLAY = r'''local storage = require("store")
local assignments = require("assignments")
local function main()
    local workspace = assert(storage.open())
    local transfers = assert(assignments.open(workspace))
    local before = assert(transfers:get({view_id = "history-view", instance_id = "history-instance"}))
    local replay = assert(transfers:prepare({request_id = "history-1", view_id = "history-view", instance_id = "history-instance", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1}))
    assert(replay.phase == "committed")
    local conflict, conflict_error = transfers:prepare({request_id = "history-1", view_id = "history-view", instance_id = "history-instance", source_display_id = "display-a", target_display_id = "display-c", expected_revision = 1})
    assert(not conflict and conflict_error and conflict_error:find("conflicts"))
    local after = assert(transfers:get({view_id = "history-view", instance_id = "history-instance"}))
    assert(after.assignment.display_id == before.assignment.display_id and after.assignment.revision == before.assignment.revision)
    assert(transfers:retire({view_id = "history-view", instance_id = "history-instance"}))
    local retired, retired_error = transfers:get({view_id = "history-view", instance_id = "history-instance"})
    assert(not retired and not retired_error)
    assert(assert(transfers:prepare({request_id = "history-1", view_id = "history-view", instance_id = "history-instance", source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1})).phase == "committed")
    assert(workspace:close())
end
return {main = main}
'''

THREAD_BINDING_PREPARE = r'''local storage = require("store")
local thread_bindings = require("thread_bindings")
local function main()
    local workspace = assert(storage.open())
    local bindings = assert(thread_bindings.open(workspace))
    local function make(instance_id, thread_id, definition_id, actor_id, idempotency_key)
        return {instance_id = instance_id, thread_id = thread_id, definition_id = definition_id, actor_id = actor_id,
            role = "participant", idempotency_key = idempotency_key, definition_revision = "revision-1",
            initiating_owner_id = "owner-1", gateway_binding_id = "gateway-binding-1", gateway_approval_id = "approval-1",
            gateway_proposal_digest = string.rep("a", 64), access = "observe_post", join_expected_revision = 7}
    end
    local invalid = {
        {},
        make("instance", string.char(195, 169), "definition", "actor", "key"),
        make("instance", "thread", "definition", "actor", "key"),
        make("instance", "thread\nvalue", "definition", "actor", "key"),
        make("instance", "thread", "definition", "actor", string.rep("k", 161)),
        make("instance", "thread", "definition", "actor", "key"),
    }
    invalid[3].role = "observer"
    invalid[6].extra = "refused"
    for _, input in ipairs(invalid) do
        local value, value_error = bindings:prepare(input)
        assert(not value and value_error)
    end

    local request = make("bound-instance", "bound-thread", "app:one", "bee.application:actor", "bind-once")
    local prepared = assert(bindings:prepare(request))
    assert(prepared.instance_id == request.instance_id and prepared.thread_id == request.thread_id
        and prepared.definition_id == request.definition_id and prepared.actor_id == request.actor_id
        and prepared.role == "participant" and prepared.binding_revision == 1 and prepared.state == "pending"
        and prepared.idempotency_key == request.idempotency_key and prepared.definition_revision == "revision-1"
        and prepared.gateway_proposal_digest == string.rep("a", 64) and prepared.access == "observe_post"
        and prepared.join_expected_revision == 7 and prepared.membership_revision == nil
        and prepared.cleanup_pending == 0 and prepared.cleanup_expected_revision == nil)
    local replay = assert(bindings:prepare(request))
    assert(replay.binding_revision == 1 and replay.state == "pending")
    local conflict_request = make(request.instance_id, "other-thread", request.definition_id, request.actor_id, request.idempotency_key)
    local conflict, conflict_error = bindings:prepare(conflict_request)
    assert(not conflict and conflict_error and conflict_error:find("conflicts"))
    local key_conflict_request = make("other-instance", request.thread_id, request.definition_id, request.actor_id, request.idempotency_key)
    local key_conflict, key_error = bindings:prepare(key_conflict_request)
    assert(not key_conflict and key_error and key_error:find("idempotency"))
    local current = assert(bindings:get({instance_id = request.instance_id}))
    assert(current.thread_id == request.thread_id and current.state == "pending")
    local listed = assert(bindings:list())
    assert(#listed == 1 and listed[1].instance_id == request.instance_id)
    assert(workspace:close())
end
return {main = main}
'''

THREAD_BINDING_ACTIVE = r'''local storage = require("store")
local thread_bindings = require("thread_bindings")
local function main()
    local workspace = assert(storage.open())
    local bindings = assert(thread_bindings.open(workspace))
    local before = assert(bindings:get("bound-instance"))
    assert(before.binding_revision == 1 and before.state == "pending")
    local refreshed_join = assert(bindings:refresh_join({instance_id = "bound-instance", expected_revision = 1,
        expected_state = "pending", join_expected_revision = 8}))
    assert(refreshed_join.binding_revision == 2 and refreshed_join.state == "pending" and refreshed_join.join_expected_revision == 8)
    local stale, stale_error = bindings:activate({instance_id = "bound-instance", expected_revision = 1, expected_state = "pending", membership_revision = 11})
    assert(not stale and stale_error and stale_error:find("changed"))
    local active = assert(bindings:activate({instance_id = "bound-instance", expected_revision = 2, expected_state = "pending", membership_revision = 11}))
    assert(active.binding_revision == 3 and active.state == "active" and active.membership_revision == 11)
    local stale_again, stale_again_error = bindings:activate({instance_id = "bound-instance", expected_revision = 1, expected_state = "pending", membership_revision = 11})
    assert(not stale_again and stale_again_error and stale_again_error:find("changed"))
    local immutable, immutable_error = bindings:prepare({instance_id = "bound-instance", thread_id = before.thread_id,
        definition_id = before.definition_id, actor_id = "another-actor", role = "participant", idempotency_key = before.idempotency_key,
        definition_revision = before.definition_revision, initiating_owner_id = before.initiating_owner_id,
        gateway_binding_id = before.gateway_binding_id, gateway_approval_id = before.gateway_approval_id,
        gateway_proposal_digest = before.gateway_proposal_digest, access = before.access,
        join_expected_revision = before.join_expected_revision})
    assert(not immutable and immutable_error and immutable_error:find("conflicts"))
    local replay = assert(bindings:prepare({instance_id = "bound-instance", thread_id = before.thread_id,
        definition_id = before.definition_id, actor_id = before.actor_id, role = "participant", idempotency_key = before.idempotency_key,
        definition_revision = before.definition_revision, initiating_owner_id = before.initiating_owner_id,
        gateway_binding_id = before.gateway_binding_id, gateway_approval_id = before.gateway_approval_id,
        gateway_proposal_digest = before.gateway_proposal_digest, access = before.access,
        join_expected_revision = before.join_expected_revision}))
    assert(replay.binding_revision == 3 and replay.state == "active" and replay.membership_revision == 11)
    local refreshed_join_again, refreshed_join_error = bindings:refresh_join({instance_id = "bound-instance", expected_revision = 3,
        expected_state = "pending", join_expected_revision = 12})
    assert(not refreshed_join_again and refreshed_join_error and refreshed_join_error:find("changed"))
    assert(workspace:close())
end
return {main = main}
'''

THREAD_BINDING_REVOKE = r'''local storage = require("store")
local thread_bindings = require("thread_bindings")
local function main()
    local workspace = assert(storage.open())
    local bindings = assert(thread_bindings.open(workspace))
    local before = assert(bindings:get("bound-instance"))
    assert(before.binding_revision == 3 and before.state == "active" and before.membership_revision == 11)
    local stale, stale_error = bindings:begin_revoke({instance_id = "bound-instance", expected_revision = 1,
        expected_state = "active", cleanup_expected_revision = 11})
    assert(not stale and stale_error and stale_error:find("changed"))
    local revoked = assert(bindings:begin_revoke({instance_id = "bound-instance", expected_revision = 3,
        expected_state = "active", cleanup_expected_revision = 11}))
    assert(revoked.binding_revision == 4 and revoked.state == "revoked" and revoked.cleanup_pending == 1
        and revoked.cleanup_expected_revision == 11)
    assert(#assert(bindings:list()) == 1)
    local second, second_error = bindings:begin_revoke({instance_id = "bound-instance", expected_revision = 4,
        expected_state = "revoked", cleanup_expected_revision = 11})
    assert(not second and second_error and second_error:find("invalid"))
    local unrevoked, unrevoked_error = bindings:activate({instance_id = "bound-instance", expected_revision = 4,
        expected_state = "revoked", membership_revision = 11})
    assert(not unrevoked and unrevoked_error and unrevoked_error:find("transition"))
    local refreshed, refresh_error = bindings:refresh_cleanup({instance_id = "bound-instance", expected_revision = 4,
        expected_state = "revoked", cleanup_expected_revision = 12})
    assert(refreshed and not refresh_error and refreshed.binding_revision == 5 and refreshed.cleanup_expected_revision == 12)
    local finish_stale, finish_stale_error = bindings:finish_revoke({instance_id = "bound-instance", expected_revision = 4, expected_state = "revoked"})
    assert(not finish_stale and finish_stale_error and finish_stale_error:find("changed"))
    local finished = assert(bindings:finish_revoke({instance_id = "bound-instance", expected_revision = 5, expected_state = "revoked"}))
    assert(finished.binding_revision == 6 and finished.state == "revoked" and finished.cleanup_pending == 0
        and finished.cleanup_expected_revision == nil)
    local replay = assert(bindings:prepare({instance_id = "bound-instance", thread_id = before.thread_id,
        definition_id = before.definition_id, actor_id = before.actor_id, role = "participant", idempotency_key = before.idempotency_key,
        definition_revision = before.definition_revision, initiating_owner_id = before.initiating_owner_id,
        gateway_binding_id = before.gateway_binding_id, gateway_approval_id = before.gateway_approval_id,
        gateway_proposal_digest = before.gateway_proposal_digest, access = before.access,
        join_expected_revision = before.join_expected_revision}))
    assert(replay.binding_revision == 6 and replay.state == "revoked" and replay.cleanup_pending == 0)
    local listed = assert(bindings:list())
    assert(#listed == 0)

    -- Revoked rows are retained tombstones and do not block recovery listing or
    -- a later logical instance from consuming the live binding capacity.
    for index = 1, 256 do
        local instance_id = "old-" .. tostring(index)
        assert(bindings:prepare({instance_id = instance_id, thread_id = "thread-" .. tostring(index),
            definition_id = "app:old", actor_id = "actor:old:" .. tostring(index), role = "participant",
            idempotency_key = "old-key-" .. tostring(index), definition_revision = "revision-old",
            initiating_owner_id = "owner-old", gateway_binding_id = "binding-old:" .. tostring(index),
            gateway_approval_id = "approval-old:" .. tostring(index), gateway_proposal_digest = string.rep("b", 64),
            access = "observe_post", join_expected_revision = 1}))
        local retired = assert(bindings:begin_revoke({instance_id = instance_id, expected_revision = 1,
            expected_state = "pending", cleanup_expected_revision = 1}))
        assert(retired.cleanup_pending == 1 and retired.state == "revoked")
        assert(bindings:finish_revoke({instance_id = instance_id, expected_revision = 2, expected_state = "revoked"}))
    end
    assert(#assert(bindings:list()) == 0)
    local fresh = assert(bindings:prepare({instance_id = "fresh-instance", thread_id = "fresh-thread",
        definition_id = "app:fresh", actor_id = "fresh-actor", role = "participant", idempotency_key = "fresh-key",
        definition_revision = "revision-fresh", initiating_owner_id = "owner-fresh", gateway_binding_id = "binding-fresh",
        gateway_approval_id = "approval-fresh", gateway_proposal_digest = string.rep("c", 64),
        access = "observe_post", join_expected_revision = 1}))
    assert(fresh.state == "pending" and fresh.binding_revision == 1)
    assert(workspace:close())
end
return {main = main}
'''

THREAD_BINDING_RESTART = r'''local storage = require("store")
local thread_bindings = require("thread_bindings")
local function main()
    local workspace = assert(storage.open())
    local bindings = assert(thread_bindings.open(workspace))
    local revoked = assert(bindings:get("bound-instance"))
    assert(revoked.thread_id == "bound-thread" and revoked.definition_id == "app:one"
        and revoked.actor_id == "bee.application:actor" and revoked.binding_revision == 6 and revoked.state == "revoked"
        and revoked.cleanup_pending == 0)
    local fresh = assert(bindings:get("fresh-instance"))
    assert(fresh.state == "pending" and fresh.binding_revision == 1)
    local active_count = 0
    for _, value in ipairs(assert(bindings:list())) do
        active_count = active_count + 1
        assert(value.instance_id == "fresh-instance" and value.state == "pending")
    end
    assert(active_count == 1)
    assert(workspace:close())
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


def assignment_acceptance(project, probe, folder):
    """Exercise durable fences and receipt history through the real runtime."""
    def phase(source):
        (probe / "main.lua").write_text(source)
        run_probe(project, folder)

    folder.mkdir()
    phase(ASSIGNMENT_PREPARE)
    phase(ASSIGNMENT_PREPARED)  # Reopen must retain source and prepared fence.
    database = folder / "workspace.db"
    with sqlite3.connect(database) as db:
        db.execute("CREATE TRIGGER fail_assignment_receipt BEFORE UPDATE OF phase ON workspace_display_transfer_receipts WHEN NEW.phase = 'committed' BEGIN SELECT RAISE(ABORT, 'forced receipt failure'); END")
    phase(ASSIGNMENT_COMMIT_FAILS)
    phase(ASSIGNMENT_PREPARED)  # The assignment UPDATE rolled back with receipt failure.
    with sqlite3.connect(database) as db:
        db.execute("DROP TRIGGER fail_assignment_receipt")
    phase(ASSIGNMENT_COMMIT)
    phase(ASSIGNMENT_HISTORY)
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT count(*) FROM workspace_display_transfer_receipts WHERE view_id='history-view' AND instance_id='history-instance'").fetchone()[0] == 65
    phase(ASSIGNMENT_HISTORY_REPLAY)
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT phase FROM workspace_display_transfer_receipts WHERE request_id='history-1'").fetchone() == ("committed",)
        assert db.execute("SELECT count(*) FROM workspace_display_assignments WHERE view_id='history-view' AND instance_id='history-instance'").fetchone() == (0,)


def thread_binding_acceptance(project, probe, folder):
    """Exercise immutable application/thread bindings through restarts."""
    def phase(source):
        (probe / "main.lua").write_text(source)
        run_probe(project, folder)

    folder.mkdir()
    phase(THREAD_BINDING_PREPARE)
    phase(THREAD_BINDING_ACTIVE)
    phase(THREAD_BINDING_REVOKE)
    phase(THREAD_BINDING_RESTART)
    database = folder / "workspace.db"
    with sqlite3.connect(database) as db:
        columns = [row[1] for row in db.execute("PRAGMA table_info(workspace_application_thread_bindings)")]
        assert columns == [
            "instance_id", "thread_id", "definition_id", "actor_id", "role",
            "binding_revision", "state", "idempotency_key", "definition_revision",
            "initiating_owner_id", "gateway_binding_id", "gateway_approval_id",
            "gateway_proposal_digest", "access", "join_expected_revision",
            "membership_revision", "cleanup_pending", "cleanup_expected_revision",
        ]
        assert not set(columns) & {
            "pid", "launch_token", "mount", "scope", "execution_generation", "database_id", "app_data",
        }
        assert db.execute(
            "SELECT state, binding_revision, access, cleanup_pending, cleanup_expected_revision FROM workspace_application_thread_bindings WHERE instance_id='bound-instance'"
        ).fetchone() == ("revoked", 6, "observe_post", 0, None)
        assert db.execute(
            "SELECT count(*) FROM workspace_application_thread_bindings WHERE state IN ('pending', 'active')"
        ).fetchone() == (1,)


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
                "imports": {"store": "bee.storage:store", "assignments": "bee.storage:assignments", "thread_bindings": "bee.storage:thread_bindings"},
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
            assert len(migration) == 5 and [row[0] for row in migration] == [1, 2, 3, 4, 5]
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
                "VALUES (6, 'future_schema', 'future', 'now')"
            )
            connection.commit()
        assert "newer than this Bee build" in run_probe(project, folder, expect_success=False)
        with sqlite3.connect(database) as connection:
            connection.execute("DELETE FROM workspace_schema_migrations WHERE id = 6")
            connection.commit()
        run_probe(project, folder)

        def identity(path):
            with sqlite3.connect(path) as db:
                return db.execute("SELECT workspace_id FROM workspace_identity WHERE singleton=1").fetchone()[0]

        original_id = identity(database)
        run_probe(project, folder)
        assert identity(database) == original_id, "Reopen changed workspace identity"
        with sqlite3.connect(database) as db:
            assert db.execute("SELECT display_id, revision FROM workspace_display_assignments WHERE view_id='view-one' AND instance_id='instance-one'").fetchone() == ("display-b", 2)
            assert db.execute("SELECT phase FROM workspace_display_transfer_receipts WHERE request_id='move-three'").fetchone() == ("committed",)
            db.execute("UPDATE workspace_display_assignments SET revision = 9007199254740990 WHERE view_id='view-17' AND instance_id='instance-17'")
        (probe / "main.lua").write_text(EXHAUSTION_PROBE)
        run_probe(project, folder)
        (probe / "main.lua").write_text(PROBE)
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

        assignment_acceptance(project, probe, folder / "assignment-acceptance")
        thread_binding_acceptance(project, probe, folder / "thread-binding-acceptance")

        # Upgrade a populated migration-4 binding table.  Those rows were
        # never consumed by a membership owner, so migration 5 must preserve
        # their identity while fencing all three as cleanup-complete tombstones.
        migration4 = folder / "migration4-bindings"
        migration4.mkdir()
        store_source = (ROOT / "src/core/storage/store.lua").read_text()

        def migration_body(constant):
            body = re.search(rf"local {constant} = \[\[(.*?)\]\]", store_source, re.S).group(1)
            return body.removeprefix("\n")

        migration_sql = {
            "workspace_state_v1": migration_body("STATE_TABLE_SQL"),
            "workspace_identity_v1": migration_body("IDENTITY_TABLE_SQL"),
            "workspace_display_assignments_v1": migration_body("DISPLAY_ASSIGNMENTS_TABLE_SQL"),
            "workspace_application_thread_bindings_v1": migration_body("APPLICATION_THREAD_BINDINGS_TABLE_SQL"),
        }
        migration_checksums = {
            name: hashlib.sha256((name + "\n" + body).encode()).hexdigest()
            for name, body in migration_sql.items()
        }
        with sqlite3.connect(migration4 / "workspace.db") as db:
            for body in migration_sql.values():
                db.executescript(body)
            db.execute("CREATE TABLE workspace_schema_migrations (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)")
            for migration_id, name in enumerate(migration_sql, 1):
                db.execute("INSERT INTO workspace_schema_migrations VALUES (?, ?, ?, 'before')",
                           (migration_id, name, migration_checksums[name]))
            db.executemany(
                "INSERT INTO workspace_application_thread_bindings VALUES (?, ?, ?, ?, 'participant', ?, ?, ?)",
                [
                    ("legacy-pending", "thread-pending", "app:legacy", "actor:pending", 4, "pending", "legacy-key-pending"),
                    ("legacy-active", "thread-active", "app:legacy", "actor:active", 7, "active", "legacy-key-active"),
                    ("legacy-revoked", "thread-revoked", "app:legacy", "actor:revoked", 9, "revoked", "legacy-key-revoked"),
                ],
            )
        migration4_probe = r'''local storage = require("store")
local thread_bindings = require("thread_bindings")
local function main()
    local workspace = assert(storage.open())
    local bindings = assert(thread_bindings.open(workspace))
    local expected = {
        ["legacy-pending"] = {thread_id = "thread-pending", actor_id = "actor:pending", revision = 4, key = "legacy-key-pending"},
        ["legacy-active"] = {thread_id = "thread-active", actor_id = "actor:active", revision = 7, key = "legacy-key-active"},
        ["legacy-revoked"] = {thread_id = "thread-revoked", actor_id = "actor:revoked", revision = 9, key = "legacy-key-revoked"},
    }
    for instance_id, value in pairs(expected) do
        local row = assert(bindings:get(instance_id))
        assert(row.thread_id == value.thread_id and row.actor_id == value.actor_id and row.binding_revision == value.revision
            and row.idempotency_key == value.key and row.state == "revoked" and row.definition_revision == "migration-unbound"
            and row.initiating_owner_id == "migration-unbound" and row.gateway_binding_id == "migration-unbound"
            and row.gateway_approval_id == "migration-unbound" and row.gateway_proposal_digest == string.rep("0", 64)
            and row.access == "observe_post" and row.join_expected_revision == 1 and row.membership_revision == nil
            and row.cleanup_pending == 0 and row.cleanup_expected_revision == nil)
    end
    assert(#assert(bindings:list()) == 0)
    assert(workspace:close())
end
return {main = main}
'''
        (probe / "main.lua").write_text(migration4_probe)
        run_probe(project, migration4)
        with sqlite3.connect(migration4 / "workspace.db") as db:
            assert [row[0] for row in db.execute("SELECT id FROM workspace_schema_migrations ORDER BY id")] == [1, 2, 3, 4, 5]
            assert db.execute(
                "SELECT count(*) FROM workspace_application_thread_bindings WHERE state='revoked' AND cleanup_pending=0"
            ).fetchone()[0] == 3

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
            assert [row[0] for row in db.execute("SELECT id FROM workspace_schema_migrations ORDER BY id")] == [1, 2, 3, 4, 5]
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

    print("Storage: WAL, migration ledger integrity/newer-version rejection, generation CAS, close behavior, stable identity, legacy upgrade/rollback, relocation, fresh identity and corrupt identity denial; immutable application/thread binding replay, CAS transitions, restart recovery and revoked tombstones")


def client_storage():
    """Native Lua owns the assertions; these files simulate process/DB failures."""
    with tempfile.TemporaryDirectory(prefix="bee-client-storage-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/client_storage", project / "src/client_storage_probe")
        host = project / "src/environment/_index.yaml"
        configuration = yaml.safe_load(host.read_text())
        next(e for e in configuration["entries"] if e["name"] == "client_db")["file"] = "${env:bee:client_db_path}"
        configuration["entries"] += [
            {"name": "client_db_path", "kind": "env.variable", "storage": "bee:workspace_environment",
             "variable": "BEE_CLIENT_DB", "default": str(root / "build-client.db"), "readonly": True},
        ]
        host.write_text(yaml.safe_dump(configuration, sort_keys=False))
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
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
            authority = root / ("authority-pack" if packed else "authority-source")
            probe(authority, "none", packed, command="client-desktop-unauthorized")
            with sqlite3.connect(authority / "client.db") as db:
                assert db.execute("SELECT count(*) FROM sqlite_master WHERE name='client_state'").fetchone()[0] == 0
            probe(authority, "seed", packed, command="client-desktop-authority")
            probe(authority, "verify", packed, command="client-desktop-authority")
            probe(authority, "reader", packed, command="client-desktop-reader")
            probe(authority, "none", packed, command="client-desktop-unauthorized")
            probe(authority, "capacity", packed, command="client-desktop-authority")
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
            # The durable catalog must refuse an oversized or ambiguous set;
            # only this disposable database is changed for fault injection.
            with sqlite3.connect(database) as db:
                db.execute("INSERT INTO client_desktops (client_id) VALUES (?)", ("c" * 32,))
            probe(folder, "catalog", packed, "Desktop catalog is corrupt")
            with sqlite3.connect(database) as db:
                db.execute("DELETE FROM client_desktops WHERE client_id = ?", ("c" * 32,))
                db.execute("UPDATE client_desktops SET client_id = ? WHERE client_id = ?", (original[0], "a" * 32))
            probe(folder, "catalog", packed, "Desktop catalog identity is corrupt")
            with sqlite3.connect(database) as db:
                db.execute("UPDATE client_desktops SET client_id = ? WHERE client_id = ?", ("a" * 32, original[0]))
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
    print("Client storage source/pack: independent client/workspace bindings, native grant/boundary denial, stable identity, qualified layout, generation CAS, atomic import/retry after restart, existing-layout protection, ledger and corruption denial; independent desktop catalog/isolation/CAS/capacity/restart, catalog corruption denial and populated-v1 upgrade")


if __name__ == "__main__":
    main()
    client_storage()
