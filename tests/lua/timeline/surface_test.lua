-- MIT. The timeline against the real thread owner through the model and
-- the application's own caller: subscribe, page, acknowledge, wait for
-- new records without claiming anything, resume under a new lease, and a
-- non-member refused without rows. Nothing here writes a delivery mark.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local model = require("model")
local view = require("view")
local caller = require("caller")
local appearance = require("appearance")
local harness = require("harness")
type Object = {[string]: unknown}
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function viewer(id: string): caller.Client
    local actor = security.new_actor(id)
    local viewer_scope = scope({"bee.threads:client_test_policy"})
    return caller.new(function(target: string, request: unknown): (unknown, string?)
        local result, err = funcs.new():with_actor(actor):with_scope(viewer_scope):call(target, request)
        if err then return nil, tostring(err) end
        return result, nil
    end)
end
local function ask(state: model.State, owner: caller.Client, intent: model.Intent?): model.Reply
    if not intent then error("no intent") end
    local reply = owner:invoke(intent.target, intent.request)
    if not reply then model.lost(state); return caller.unknown() end
    return reply
end
local function define_tests()
    test.describe("Timeline surface", function()
        local alice = harness.principal("bee.test.timeline_alice", harness.ALL)
        test.it("reads a thread in owner order, waits without claiming, resumes and refuses a non-member", function()
            local thread_id = harness.thread(alice, "Timeline proof")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "bee.test.timeline_bob", role = "participant", expected_revision = 1}))
            -- A request addressed to the viewer leaves a pending obligation;
            -- reading the thread must never claim or settle it.
            harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.request("q1", "please review", {"bee.test.timeline_bob"})}))
            for index = 2, 3 do
                harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.message("m" .. tostring(index), "note " .. tostring(index))}))
            end
            local db0 = harness.open()
            local pending_before = harness.query(db0, "SELECT COUNT(*) AS count FROM bee_thread_obligations WHERE thread_id = ? AND recipient_id = ? AND state = 'pending'", {thread_id, "bee.test.timeline_bob"})
            db0:release()
            test.eq(pending_before[1].count, 1)
            local bob = viewer("bee.test.timeline_bob")
            local state = model.new("bee.timeline.proof")
            model.apply_list(state, ask(state, bob, model.list_intent(state)))
            test.is_true(model.picked(state) ~= nil)
            model.open(state, thread_id, nil)
            model.apply_get(state, ask(state, bob, model.get_intent(state)))
            test.eq(state.title, "Timeline proof")
            model.apply_attach(state, ask(state, bob, model.attach_intent(state, harness.key())))
            test.eq(state.phase, "attached")
            model.apply_recap(state, ask(state, bob, model.recap_intent(state)))
            test.is_true(state.recap ~= nil)
            local more = model.apply_page(state, ask(state, bob, model.page_intent(state)))
            test.is_false(more)
            test.eq(#state.rows, 3)
            test.eq(state.rows[3].summary, "request from bee.test.timeline_alice: note 3")
            test.eq(state.rows[1].summary, "request from bee.test.timeline_alice to bee.test.timeline_bob: please review")
            model.apply_ack(state, ask(state, bob, model.ack_intent(state, harness.key())))
            test.eq(state.session and state.session.after_sequence, state.rows[3].sequence)
            harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.message("m4", "note 4")}))
            local watch = model.watch_intent(state)
            if not watch then error("watch") end
            watch.request.wait_ms = 0
            model.apply_watch(state, ask(state, bob, watch))
            model.apply_page(state, ask(state, bob, model.page_intent(state)))
            test.eq(#state.rows, 4)
            model.apply_ack(state, ask(state, bob, model.ack_intent(state, harness.key())))
            -- The viewer's pending obligation and the delivery ledger are untouched by reading.
            local db = harness.open()
            local pending_after = harness.query(db, "SELECT COUNT(*) AS count FROM bee_thread_obligations WHERE thread_id = ? AND recipient_id = ? AND state = 'pending'", {thread_id, "bee.test.timeline_bob"})
            local marks = harness.query(db, "SELECT COUNT(*) AS count FROM bee_thread_records WHERE thread_id = ? AND kind = 'delivery.mark'", {thread_id})
            local batches = harness.query(db, "SELECT COUNT(*) AS count FROM bee_thread_claim_batches WHERE thread_id = ?", {thread_id})
            db:release()
            test.eq(pending_after[1].count, 1)
            test.eq(marks[1].count, 0)
            test.eq(batches[1].count, 0)
            local frame = view.draw(120, 20, appearance.defaults(), state, 0, "")
            test.is_true(table.concat(frame.rows, "\n"):find("note 4", 1, true) ~= nil)
            -- A later instance restores the checkpoint and resumes the same subscription under a new lease.
            local restored = model.new("bee.timeline.proof")
            test.is_true(model.restore(restored, model.checkpoint(state)))
            local resume = model.attach_intent(restored, harness.key())
            if not resume then error("resume") end
            test.eq(resume.target, model.RESUME)
            model.apply_attach(restored, ask(restored, bob, resume))
            test.eq(restored.phase, "attached")
            test.eq(restored.session and restored.session.lease_generation, 2)
            test.eq(restored.dropped_through, state.rows[4].sequence)
            test.is_false(model.apply_page(restored, ask(restored, bob, model.page_intent(restored))))
            test.eq(#restored.rows, 0)
            -- The earlier instance's lease is fenced: its next acknowledgment is refused and it asks for resume.
            harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.message("m5", "note 5")}))
            model.apply_page(state, ask(state, bob, model.page_intent(state)))
            test.eq(state.phase, "resume_required")
            test.eq(#state.rows, 4)
            local outsider = viewer("bee.test.timeline_outsider")
            local refused = model.new("bee.timeline.outsider")
            model.open(refused, thread_id, nil)
            model.apply_attach(refused, ask(refused, outsider, model.attach_intent(refused, harness.key())))
            test.eq(refused.phase, "unavailable")
            test.is_true(refused.unavailable:find("DENIED", 1, true) ~= nil)
            test.eq(#refused.rows, 0)
        end)
    end)
end
return require("test").run_cases(define_tests)
