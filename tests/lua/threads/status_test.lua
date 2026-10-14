-- MIT. The status projection: neutral work facts folded from records, its
-- own cursor and revision, a rebuild equal to the incremental fold, the
-- caller's waiting relationship derived per read and never persisted, a
-- pending approval counted without a decide claim, and staleness reported
-- rather than certainty. It never asserts process liveness.
local test = require("test")
local harness = require("harness")
local status = require("status")
local function define_tests()
    test.describe("Thread status projection", function()
        local alice = harness.principal("alice", harness.ALL)
        local bob = harness.principal("bob", {})
        local function started(epoch: integer): {[string]: unknown}
            return {execution_kind = "process", execution_ref = "pid-" .. tostring(epoch), owner_epoch = epoch}
        end
        test.it("folds work facts, derives the caller's waiting relationship and equals a rebuild", function()
            local thread_id = harness.thread(alice, "Status")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "bob", role = "participant", expected_revision = 1}))
            local empty = harness.value(bob:call("status_read", {thread_id = thread_id}))
            test.eq(empty.revision, 0)
            test.eq(empty.status.activity, "idle")
            test.is_false(empty.status.stale)
            -- A request addressed to bob is a neutral waiting fact; each reader
            -- derives its own relationship to it.
            harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.request("q1", "please review", {"bob"})}))
            test.eq(harness.value(bob:call("status_update", {thread_id = thread_id})).revision, 1)
            local waiting = harness.value(bob:call("status_read", {thread_id = thread_id}))
            test.eq(waiting.revision, 1)
            test.eq(waiting.status.activity, "waiting")
            test.eq(waiting.status.open_requests, 1)
            test.is_true(waiting.status.waiting_on_you)
            test.eq(waiting.status.waiting_message_ids[1], "q1")
            -- Alice, not a recipient, gets the same neutral facts but no
            -- waiting-on-you: one viewer's relationship is never thread-wide.
            local alice_view = harness.value(alice:call("status_read", {thread_id = thread_id}))
            test.eq(alice_view.status.open_requests, 1)
            test.is_false(alice_view.status.waiting_on_you)
            test.eq(#alice_view.status.waiting_message_ids, 0)
            -- A started attempt is recorded activity, not liveness.
            harness.value(alice:call("admit_action", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "act", admitted = harness.admitted()}))
            harness.value(alice:call("prepare_attempt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "act", attempt_id = "att", prepared = harness.prepared()}))
            harness.value(alice:call("start_attempt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "act", attempt_id = "att", started = started(1)}))
            local folded = harness.value(alice:call("status_update", {thread_id = thread_id}))
            local running = harness.value(alice:call("status_read", {thread_id = thread_id}))
            test.eq(running.status.activity, "running")
            test.eq(running.status.running_actions, 1)
            local rebuilt = harness.value(alice:call("status_rebuild", {thread_id = thread_id}))
            test.eq(rebuilt.digest, folded.digest)
            test.eq(rebuilt.through_sequence, folded.through_sequence)
            test.eq(harness.code(bob:call("status_rebuild", {thread_id = thread_id})), "DENIED")
        end)
        test.it("clears a request when answered, counts a pending approval without a decide claim and settles the outcome", function()
            local thread_id = harness.thread(alice, "Status two")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "bob", role = "participant", expected_revision = 1}))
            local request = harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.request("q1", "review", {"bob"})}))
            harness.value(bob:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.reply("a1", "done", thread_id, request.record_id, "succeeded")}))
            harness.value(alice:call("status_update", {thread_id = thread_id}))
            local answered = harness.value(alice:call("status_read", {thread_id = thread_id}))
            test.eq(answered.status.open_requests, 0)
            test.eq(answered.status.activity, "idle")
            test.is_false(answered.status.waiting_on_you)
            -- The engine derivation is pure over the checkpoint and the caller.
            local pending = status.derive({schema = status.SCHEMA, messages = 0, actions = {}, open_requests = {},
                pending_approvals = {["ap1"] = {requester_id = "bee.claude"}}, last_outcome = {kind = "turn", outcome = "succeeded", at_sequence = 4}, uncertain = false, last_activity_sequence = 4}, "bob", 4, 4)
            test.eq(pending.activity, "waiting")
            test.eq(pending.pending_approvals, 1)
            test.is_false(pending.waiting_on_you)
            local uncertain = status.derive({schema = status.SCHEMA, messages = 0, actions = {["a1"] = "uncertain"}, open_requests = {},
                pending_approvals = {}, last_outcome = {kind = "receipt", outcome = "uncertain", at_sequence = 4}, last_activity_sequence = 4}, "bob", 2, 9)
            test.eq(uncertain.activity, "uncertain")
            test.eq(uncertain.uncertain_actions, 1)
            test.is_true(uncertain.stale)
            -- A later unrelated request does not clear an unresolved uncertain
            -- action; only that action's own lifecycle does.
            local still = status.derive({schema = status.SCHEMA, messages = 1, actions = {["a1"] = "uncertain"}, open_requests = {["q9"] = {sender_id = "a", targets = {["bob"] = true}, remaining = 1}},
                pending_approvals = {}, last_outcome = {kind = "receipt", outcome = "uncertain", at_sequence = 4}, last_activity_sequence = 6}, "bob", 6, 6)
            test.eq(still.activity, "uncertain")
            test.is_true(still.waiting_on_you)
        end)
        test.it("clears one recipient's waiting indicator while another remains, and new work supersedes uncertainty", function()
            local thread_id = harness.thread(alice, "Fan out")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "bob", role = "participant", expected_revision = 1}))
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "carol", role = "participant", expected_revision = 2}))
            local carol = harness.principal("carol", {})
            local request = harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.request("q1", "both please", {"bob", "carol"})}))
            harness.value(bob:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.reply("a1", "bob done", thread_id, request.record_id, "succeeded")}))
            harness.value(alice:call("status_update", {thread_id = thread_id}))
            local bob_view = harness.value(bob:call("status_read", {thread_id = thread_id}))
            test.is_false(bob_view.status.waiting_on_you)
            local carol_view = harness.value(carol:call("status_read", {thread_id = thread_id}))
            test.is_true(carol_view.status.waiting_on_you)
            test.eq(carol_view.status.open_requests, 1)
            test.eq(carol_view.status.activity, "waiting")
        end)
        test.it("keeps one action uncertain while another action starts and succeeds", function()
            local thread_id = harness.thread(alice, "Two actions")
            local function run(action: string, epoch: integer)
                harness.value(alice:call("admit_action", {thread_id = thread_id, idempotency_key = harness.key(), action_id = action, admitted = harness.admitted()}))
                harness.value(alice:call("prepare_attempt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = action, attempt_id = action .. "-att", prepared = harness.prepared()}))
                harness.value(alice:call("start_attempt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = action, attempt_id = action .. "-att", started = started(epoch)}))
            end
            local function settle(action: string, outcome: string, err: {[string]: unknown}?)
                harness.value(alice:call("receipt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = action, attempt_id = action .. "-att",
                    receipt = {scope = "attempt", outcome = outcome, evidence_refs = {}, error = err}}))
                harness.value(alice:call("receipt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = action,
                    receipt = {scope = "action", outcome = outcome, evidence_refs = {}, error = err}}))
            end
            run("A", 1)
            settle("A", "uncertain", {code = "LOST", message = "reply lost", retryable = false})
            harness.value(alice:call("status_update", {thread_id = thread_id}))
            local after_a = harness.value(alice:call("status_read", {thread_id = thread_id}))
            test.eq(after_a.status.activity, "uncertain")
            test.eq(after_a.status.uncertain_actions, 1)
            run("B", 2)
            settle("B", "succeeded", nil)
            harness.value(alice:call("status_update", {thread_id = thread_id}))
            local after_b = harness.value(alice:call("status_read", {thread_id = thread_id}))
            -- B's success clears nothing for A; the thread stays uncertain.
            test.eq(after_b.status.activity, "uncertain")
            test.eq(after_b.status.uncertain_actions, 1)
            test.eq(after_b.status.running_actions, 0)
        end)
    end)
end
return require("test").run_cases(define_tests)
