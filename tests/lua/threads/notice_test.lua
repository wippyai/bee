-- MIT. One-shot notices: a member asks to be told once, on its own thread,
-- when an action it can read ends its turn or its attempt exits. The owner
-- commits one notification after the ending record, wakes a waiter on the
-- watcher's thread, and never tells twice.
local test = require("test")
local harness = require("harness")
type Object = {[string]: unknown}
local function admitted_for(principal: string): Object
    local body = harness.admitted() :: Object
    body.principal_id = principal
    return body
end
local function turn_signal(key: string, phase: string): Object
    return {type = "turn.signal", event_key = key, data = {type = "turn.signal", phase = phase}}
end
local viewer = harness.principal("alice", harness.ALL)
local function records(thread_id: string): {Object}
    local page = harness.value(viewer:call("read_after", {thread_id = thread_id, cursor = 0, limit = 64}))
    return page.records :: {Object}
end
local function notices(thread_id: string): {Object}
    local found: {Object} = {}
    for _, item in ipairs(records(thread_id)) do
        local body = item.body :: Object
        if item.kind == "message" and tostring(body.message_id):sub(1, 7) == "notice:" then found[#found + 1] = item end
    end
    return found
end
local function define_tests()
    test.describe("Thread notices", function()
        local alice = harness.principal("alice", harness.ALL)
        local bob = harness.principal("bob", harness.ALL)
        -- A watcher thread with the watcher's own action, and a target thread
        -- whose action has a started attempt.
        local function sessions(): (string, string)
            local watcher = harness.thread(alice, "Watcher session")
            local target = harness.thread(alice, "Target session")
            harness.value(alice:call("admit_action", {thread_id = watcher, idempotency_key = harness.key(), action_id = "watcher-action", admitted = admitted_for("alice")}))
            harness.value(alice:call("admit_action", {thread_id = target, idempotency_key = harness.key(), action_id = "target-action", admitted = admitted_for("alice")}))
            harness.value(alice:call("prepare_attempt", {thread_id = target, idempotency_key = harness.key(), action_id = "target-action", attempt_id = "target-attempt", prepared = harness.prepared()}))
            harness.value(alice:call("start_attempt", {thread_id = target, idempotency_key = harness.key(), action_id = "target-action", attempt_id = "target-attempt",
                started = {execution_kind = "process", execution_ref = "pid-1", owner_epoch = 1}}))
            return watcher, target
        end
        local function observe(target: string, key: string, phase: string): Object
            return harness.value(alice:call("record", {thread_id = target, idempotency_key = harness.key(), kind = "observation", source = "stream",
                body = turn_signal(key, phase), context = {action_id = "target-action", attempt_id = "target-attempt"}})) :: Object
        end
        local function notify(watcher: string, target: string, key: string, watcher_action: string?)
            local request: Object = {thread_id = watcher, idempotency_key = key, target_thread_id = target, target_action_id = "target-action"}
            if watcher_action then request.watcher_action_id = watcher_action end
            return alice:call("notify", request)
        end
        test.it("tells the watcher once when the watched action ends its turn", function()
            local watcher, target = sessions()
            local key = harness.key()
            local registered = harness.value(notify(watcher, target, key, "watcher-action"))
            test.eq(registered.state, "pending")
            local replayed = notify(watcher, target, key, "watcher-action")
            test.is_true(replayed.replayed)
            test.eq(harness.value(replayed).notice_id, registered.notice_id)
            local before = harness.head_sequence(watcher)
            observe(target, "turn-start", "started")
            test.eq(harness.head_sequence(watcher), before)
            local ended = observe(target, "turn-end", "ended")
            local told = notices(watcher)
            test.eq(#told, 1)
            local body = told[1].body :: Object
            test.eq(body.message_kind, "notification")
            test.eq(body.sender_id, "alice")
            test.eq((body.recipient_ids :: {string})[1], "alice")
            test.eq((body.recipient_action_ids :: {string})[1], "watcher-action")
            test.is_true(tostring((body.content :: Object).text):find("ended its turn", 1, true) ~= nil)
            local causation = told[1].causation :: Object
            test.eq(causation.thread_id, target)
            test.eq(causation.record_id, ended.record_id)
            observe(target, "turn-end-2", "ended")
            test.eq(#notices(watcher), 1)
        end)
        test.it("wakes a watcher blocked in a wait on its own thread", function()
            local watcher, target = sessions()
            harness.value(notify(watcher, target, harness.key(), "watcher-action"))
            local head = harness.head_sequence(watcher)
            local waiting = alice:start("watch", {thread_id = watcher, after_sequence = head, wait_ms = 20000})
            observe(target, "turn-end", "ended")
            local woke = harness.value(harness.await(waiting))
            test.eq(woke.status, "ready")
            test.eq(woke.head_sequence, head + 1)
        end)
        test.it("tells the watcher when the watched attempt exits", function()
            local watcher, target = sessions()
            harness.value(notify(watcher, target, harness.key(), nil))
            local receipt = harness.value(alice:call("receipt", {thread_id = target, idempotency_key = harness.key(), action_id = "target-action", attempt_id = "target-attempt",
                receipt = {scope = "attempt", outcome = "uncertain", evidence_refs = {}, error = {code = "lost", message = "lost", retryable = false}}}))
            local told = notices(watcher)
            test.eq(#told, 1)
            local body = told[1].body :: Object
            test.eq(body.outcome, "uncertain")
            test.is_nil(body.recipient_action_ids)
            test.is_true(tostring((body.content :: Object).text):find("exited", 1, true) ~= nil)
            test.eq((told[1].causation :: Object).record_id, receipt.record_id)
        end)
        test.it("tells at once when the watched action has no live attempt", function()
            local watcher, target = sessions()
            local receipt = harness.value(alice:call("receipt", {thread_id = target, idempotency_key = harness.key(), action_id = "target-action", attempt_id = "target-attempt",
                receipt = {scope = "attempt", outcome = "succeeded", evidence_refs = {}}}))
            local registered = harness.value(notify(watcher, target, harness.key(), "watcher-action"))
            test.eq(registered.state, "fired")
            local told = notices(watcher)
            test.eq(#told, 1)
            test.eq((told[1].causation :: Object).record_id, receipt.record_id)
            test.eq((told[1].body :: Object).outcome, "succeeded")
        end)
        test.it("refuses a watcher that cannot read the target or names another's action", function()
            local watcher, target = sessions()
            local foreign = harness.thread(bob, "Bob's session")
            test.eq(harness.code(bob:call("notify", {thread_id = foreign, idempotency_key = harness.key(), target_thread_id = target, target_action_id = "target-action"})), "DENIED")
            test.eq(harness.code(notify(watcher, target, harness.key(), "target-action")), "INVALID_ARGUMENT")
            harness.value(alice:call("join", {thread_id = watcher, idempotency_key = harness.key(), member_id = "bob", role = "participant", expected_revision = 1}))
            harness.value(bob:call("admit_action", {thread_id = watcher, idempotency_key = harness.key(), action_id = "bob-action", admitted = admitted_for("bob")}))
            test.eq(harness.code(notify(watcher, target, harness.key(), "bob-action")), "DENIED")
            test.eq(harness.code(notify(watcher, target, harness.key(), "missing-action") ), "INVALID_ARGUMENT")
            test.eq(harness.code(alice:call("notify", {thread_id = watcher, idempotency_key = harness.key(), target_thread_id = target, target_action_id = "missing"})), "NOT_FOUND")
            local observed = harness.thread(alice, "Observed")
            harness.value(alice:call("join", {thread_id = observed, idempotency_key = harness.key(), member_id = "bob", role = "observer", expected_revision = 1}))
            test.eq(harness.code(bob:call("notify", {thread_id = observed, idempotency_key = harness.key(), target_thread_id = target, target_action_id = "target-action"})), "DENIED")
            local db = harness.open()
            local rows = harness.query(db, "SELECT COUNT(*) AS count FROM bee_thread_notices WHERE target_thread_id = ?", {target})
            db:release()
            test.eq(math.floor(tonumber(rows[1].count) or -1), 0)
        end)
        test.it("cancels a notice whose watcher has left its thread", function()
            local watcher, target = sessions()
            harness.value(alice:call("join", {thread_id = watcher, idempotency_key = harness.key(), member_id = "bob", role = "participant", expected_revision = 1}))
            harness.value(alice:call("join", {thread_id = target, idempotency_key = harness.key(), member_id = "bob", role = "observer", expected_revision = 1}))
            local registered = harness.value(bob:call("notify", {thread_id = watcher, idempotency_key = harness.key(), target_thread_id = target, target_action_id = "target-action"}))
            harness.value(bob:call("leave", {thread_id = watcher, idempotency_key = harness.key(), member_id = "bob", expected_revision = 2}))
            local before = harness.head_sequence(watcher)
            observe(target, "turn-end", "ended")
            test.eq(harness.head_sequence(watcher), before)
            local db = harness.open()
            local rows = harness.query(db, "SELECT state FROM bee_thread_notices WHERE notice_id = ?", {registered.notice_id})
            db:release()
            test.eq(rows[1].state, "cancelled")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
