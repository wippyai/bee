-- MIT. Removing a session deletes what Bee keeps for it and keeps its thread.
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local registry = require("registry")
local WORKSPACE = string.rep("a", 32)
local OTHER_WORKSPACE = string.rep("b", 32)

type Object = {[string]: unknown}

local function caller(actor_id: string, workspace: string): funcs.Executor
    local actor = assert(security.new_actor(actor_id, {workspace_id = workspace}))
    return funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
        assert(security.policy("bee.tests.threads.sessions:interactive_lifecycle_policy"))}))
end

local function reply_of(executor: funcs.Executor, method: string, request: Object): Object
    local raw, err = executor:call("bee.threads.sessions.binding:" .. method, request)
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end

local function value_of(reply: Object): Object
    if reply.ok ~= true then error(tostring((bounds.object(reply.error) or {}).message)) end
    return assert(bounds.object(reply.value))
end

local function count(statement: string, params: {unknown}): integer
    local db = harness.open()
    local rows = harness.query(db, statement, params)
    db:release()
    return math.floor(tonumber(rows[1].count) or -1)
end

-- kept_rows counts every row Bee keeps only for session.
local function kept_rows(session: string): integer
    local total = 0
    for _, statement in ipairs({
        "SELECT COUNT(*) AS count FROM bee_sessions WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_work WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_turns WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_work_cancellations c JOIN bee_session_work w ON w.work_ref = c.work_ref WHERE w.session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_traits WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_trait_intervals WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_hook_invocations WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_hook_originals WHERE session_ref = ?",
        "SELECT COUNT(*) AS count FROM bee_session_operations WHERE target_ref = ? AND operation <> 'session_remove'",
        "SELECT COUNT(*) AS count FROM bee_thread_carriers WHERE json_extract(checkpoint_json, '$.retained_session_ref') = ?",
    }) do total = total + count(statement, {session}) end
    return total
end

-- seed_session_state writes the trait, hook and carrier rows a running
-- session accumulates, so removal is proven against each of them.
local function seed_session_state(session: string, thread: string)
    local db = harness.open()
    harness.execute(db, "INSERT INTO bee_session_traits(session_ref, trait_id, thread_id, workspace_id, declaration_json, grant_id, selected, revision) VALUES (?, 'trait', ?, ?, '{}', 'grant', 1, 1)",
        {session, thread, WORKSPACE})
    harness.execute(db, "INSERT INTO bee_session_trait_intervals(session_ref, trait_id, generation, start_sequence, declaration_json) VALUES (?, 'trait', 1, 1, '{}')", {session})
    local invocation = "invocation-" .. harness.key()
    harness.execute(db, "INSERT INTO bee_session_hook_invocations(invocation_id, occurrence_key, session_ref, trait_id, selection_revision, point, state) VALUES (?, ?, ?, 'trait', 1, 'stop', 'completed')",
        {invocation, harness.key(), session})
    harness.execute(db, "INSERT INTO bee_session_hook_originals(record_ref, invocation_id, session_ref, trait_id, grant_id, original_json) VALUES (?, ?, ?, 'trait', 'grant', '{}')",
        {"record-" .. harness.key(), invocation, session})
    db:release()
    -- A carrier checkpoint belongs to a thread attempt the lifecycle admits;
    -- the checkpoint row alone is what removal must forget.
    db = harness.open()
    local attempt = "attempt-" .. harness.key()
    harness.execute(db, "PRAGMA foreign_keys = OFF")
    harness.execute(db, "INSERT INTO bee_thread_carriers(thread_id, attempt_id, carrier_epoch, checkpoint_revision, checkpoint_json, updated_at) VALUES (?, ?, 1, 1, ?, '2026-10-31T00:00:00Z')",
        {thread, attempt, '{"retained_session_ref":"' .. session .. '"}'})
    harness.execute(db, "PRAGMA foreign_keys = ON")
    db:release()
end

-- with_placement runs body with the fixture placement reconcile answering
-- as handler names, then restores it.
local function with_placement(handler: string, body: () -> ())
    local original = assert(registry.get("bee.tests.threads.sessions:removal_placement"))
    local replaced = assert(registry.get("bee.tests.threads.sessions:" .. handler))
    replaced.id = "bee.tests.threads.sessions:removal_placement"
    local swap = assert(registry.snapshot()):changes()
    swap:update(replaced)
    assert(swap:apply())
    local ok, failure = pcall(body)
    local restore = assert(registry.snapshot()):changes()
    restore:update(original)
    assert(restore:apply())
    if not ok then error(tostring(failure)) end
end

local function define_tests()
    test.describe("Session removal", function()
        test.it("removes an idle session and everything kept for it while its thread stays", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {}}))
            local session = assert(bounds.id(opened.session))
            local stored = harness.value(journal:call("session_describe", {session = session}))
            local thread = assert(bounds.id(stored.thread_ref))
            local work = harness.value(journal:call("work_send", {session = session, input = "queued", operation_key = harness.key()}))
            local owner = caller("sessions-owner", WORKSPACE)
            value_of(reply_of(owner, "cancel", {work = work.work, operation_key = harness.key()}))
            seed_session_state(session, thread)
            test.is_true(kept_rows(session) > 0)
            local records = count("SELECT COUNT(*) AS count FROM bee_thread_records WHERE thread_id = ?", {thread})
            local removed = value_of(reply_of(owner, "remove", {session = session, operation_key = harness.key()}))
            test.eq(removed.state, "removed")
            test.eq(removed.session, session)
            test.eq(kept_rows(session), 0)
            test.eq(count("SELECT COUNT(*) AS count FROM bee_thread_heads WHERE thread_id = ?", {thread}), 1)
            test.is_true(count("SELECT COUNT(*) AS count FROM bee_thread_records WHERE thread_id = ?", {thread}) >= records)
            test.eq(harness.code(journal:call("session_describe", {session = session})), "NOT_FOUND")
            local page = value_of(reply_of(owner, "list", {filter = {workspace = WORKSPACE}}))
            for _, row in ipairs(assert(bounds.array(page.items, 4096))) do
                test.neq((assert(bounds.object(row))).session, session)
            end
            local restored = reply_of(owner, "restore", {session = session})
            test.is_false(restored.ok)
        end)
        test.it("answers a repeated remove with the same key as the first, without removing anything else", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {}}))
            local session = assert(bounds.id(opened.session))
            local owner = caller("sessions-owner", WORKSPACE)
            local key = harness.key()
            local first = value_of(reply_of(owner, "remove", {session = session, operation_key = key}))
            local second = value_of(reply_of(owner, "remove", {session = session, operation_key = key}))
            test.eq(second.state, "removed")
            test.eq(second.operation, first.operation)
            local other = reply_of(owner, "remove", {session = session, operation_key = harness.key()})
            test.is_false(other.ok)
            test.eq((assert(bounds.object(other.error))).code, "NOT_FOUND")
        end)
        test.it("denies removal to a caller outside the session's workspace", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {}}))
            local session = assert(bounds.id(opened.session))
            local denied = reply_of(caller("intruder", OTHER_WORKSPACE), "remove", {session = session, operation_key = harness.key()})
            test.is_false(denied.ok)
            test.eq((assert(bounds.object(denied.error))).code, "DENIED")
            test.eq(harness.value(journal:call("session_describe", {session = session})).state, "active")
        end)
        test.it("stops a running window session first and removes it once placement proves its exit", function()
            local journal = harness.session_owner(WORKSPACE)
            local methods = {reconcile = "bee.tests.threads.sessions:removal_placement", stop = "bee.tests.threads.sessions:removal_placement"}
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook", placement_methods = methods,
                owner_id = "sessions-owner", workspace_id = WORKSPACE}}))
            local session = assert(bounds.id(opened.session))
            local attempt = "removal-" .. harness.key()
            harness.value(journal:call("session_attach", {session = session, attempt_id = attempt, operation_key = harness.key()}))
            local owner = caller("sessions-owner", WORKSPACE)
            local key = harness.key()
            with_placement("interactive_running", function()
                local pending = value_of(reply_of(owner, "remove", {session = session, operation_key = key}))
                test.eq(pending.state, "removing")
                test.eq(harness.value(journal:call("session_describe", {session = session})).state, "closing")
            end)
            with_placement("interactive_exited", function()
                value_of(reply_of(owner, "detach", {session = session, attempt_id = attempt, operation_key = harness.key()}))
            end)
            test.eq(harness.code(journal:call("session_describe", {session = session})), "NOT_FOUND")
            test.eq(kept_rows(session), 0)
            local replay = value_of(reply_of(owner, "remove", {session = session, operation_key = key}))
            test.eq(replay.session, session)
        end)
    end)
end
return test.run_cases(define_tests)
