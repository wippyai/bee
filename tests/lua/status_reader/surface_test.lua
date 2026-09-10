-- MIT. The reader against the real thread owner through its intents and a
-- viewer's own caller: bind, advance the projection through the bounded
-- update, derive the caller's status through read, recheck through the
-- read-only change-wait, and see a new record raise the activity. It writes
-- nothing and derives each viewer's own waiting relationship.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local reader = require("reader")
local caller = require("caller")
local harness = require("harness")
type Object = {[string]: unknown}
local function viewer(id: string): caller.Client
    local actor = security.new_actor(id)
    local policy, err = security.policy("bee.threads:client_test_policy")
    if err or not policy then error("policy: " .. tostring(err)) end
    local scope = security.new_scope({policy})
    return caller.new(function(target: string, request: unknown): (unknown, string?)
        local result, call_error = funcs.new():with_actor(actor):with_scope(scope):call(target, request)
        if call_error then return nil, tostring(call_error) end
        return result, nil
    end)
end
local function refresh(r: reader.Reader, owner: caller.Client)
    local update = reader.update_intent(r, harness.key())
    if update then reader.apply_update(r, update.generation, owner:invoke(update.target, update.request) or caller.unknown()) end
    local read = reader.read_intent(r)
    if read then reader.apply_read(r, read.generation, owner:invoke(read.target, read.request) or caller.unknown()) end
end
local function define_tests()
    test.describe("Status reader surface", function()
        local alice = harness.principal("bee.test.status_alice", harness.ALL)
        test.it("advances, derives the viewer's waiting relationship, and rechecks with the change-wait", function()
            local thread_id = harness.thread(alice, "Status reader")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "bee.test.status_bob", role = "participant", expected_revision = 1}))
            harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.request("q1", "please review", {"bee.test.status_bob"})}))
            local bob = viewer("bee.test.status_bob")
            local r = reader.new()
            reader.bind(r, thread_id)
            refresh(r, bob)
            test.eq(r.availability, "ready")
            test.eq(r.status and r.status.activity, "waiting")
            test.is_true(r.status and r.status.waiting_on_you)
            test.eq(r.status and r.status.waiting_message_ids[1], "q1")
            test.is_false(reader.value(r).stale)
            -- The viewer's own caller derives its own relationship: alice, the
            -- sender, is not waiting on herself.
            local alice_reader = reader.new()
            reader.bind(alice_reader, thread_id)
            refresh(alice_reader, viewer("bee.test.status_alice"))
            test.is_false(alice_reader.status and alice_reader.status.waiting_on_you)
            test.eq(alice_reader.status and alice_reader.status.open_requests, 1)
            -- The change-wait returns at once because the head is past the cursor.
            local watch = reader.watch_intent(r)
            if not watch then error("watch") end
            watch.request.wait_ms = 0
            reader.apply_watch(r, watch.generation, bob:invoke(watch.target, watch.request) or caller.unknown())
            -- A new record moves the head; the next refresh reflects it and the
            -- reader wrote nothing.
            harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.message("m2", "another")}))
            refresh(r, bob)
            test.is_true(r.status and r.status.open_requests >= 1)
            local db = harness.open()
            local marks = harness.query(db, "SELECT COUNT(*) AS count FROM bee_thread_records WHERE thread_id = ? AND kind = 'delivery.mark'", {thread_id})
            db:release()
            test.eq(marks[1].count, 0)
        end)
    end)
end
return require("test").run_cases(define_tests)
