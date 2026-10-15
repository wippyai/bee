-- MIT. Approval service decisions.
local test = require("test")
local events = require("events")
local principals = require("principals")
local bounds = require("bounds")
local json = require("json")
local time = require("time")
local channel = require("channel")
local service = require("service")
local fixture = require("fixture").new()
local REQUESTER = fixture.REQUESTER
local ALICE = fixture.ALICE
local BOB = fixture.BOB
local OUTBOX = fixture.OUTBOX
local key = fixture.key
local scope = fixture.scope
local requester = fixture.requester
local other_requester = fixture.other_requester
local alice = fixture.alice
local bob = fixture.bob
local outsider = fixture.outsider
local manager = fixture.manager
local call = fixture.call
local value = fixture.value
local code = fixture.code
local await = fixture.await
local open_test_store = fixture.open_test_store
local executed = fixture.executed
local fault_value = fixture.fault_value
local proposal = fixture.proposal
local request_of = fixture.request_of
local retire_owned_effects = fixture.retire_owned_effects

local function define_tests()
    test.describe("Approval owner decisions", function()
        fixture.setup("bee.tests.approvals:service_decisions_db", true)
        test.after_all(retire_owned_effects)
        test.it("decides several requests of one requester as one batch", function()
            local workspace = "ws-batch-" .. key()
            local first = value(call(requester, "request", request_of(workspace)))
            local second = value(call(requester, "request", request_of(workspace)))
            local changed = assert(events.subscribe(service.ATTENTION, "approval.changed"))
            local settled = value(call(alice, "decide_batch", {decisions = {
                {approval_id = first.approval_id, expected_revision = first.revision, proposal_digest = first.proposal_digest, reviewed_digest = first.reviewed_digest, decision = "approved"},
                {approval_id = second.approval_id, expected_revision = second.revision, proposal_digest = second.proposal_digest, reviewed_digest = second.reviewed_digest, decision = "denied"}}}))
            local views = principals.objects(settled.decisions)
            test.eq(#views, 2)
            test.eq(views[1].decision, "approved")
            test.eq(views[2].decision, "denied")
            local update = channel.select({changed:channel():case_receive(), time.after("1s"):case_receive()})
            changed:close()
            test.eq(update.channel, changed:channel())
            test.eq(assert(bounds.object(update.value.data)).count, 0)
            test.eq(value(call(alice, "read", {approval_id = first.approval_id})).state, "decided")
        end)
        test.it("refuses a batch across requesters or with a stale item without deciding any", function()
            local workspace = "ws-batch-mixed-" .. key()
            local mine = value(call(requester, "request", request_of(workspace)))
            local theirs = value(call(other_requester, "request", request_of(workspace)))
            local item = function(view: {[string]: unknown}, revision: integer?): {[string]: unknown}
                return {approval_id = view.approval_id, expected_revision = revision or view.revision,
                    proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, decision = "approved"}
            end
            test.eq(code(call(alice, "decide_batch", {decisions = {item(mine), item(theirs)}})), "INVALID_ARGUMENT")
            test.eq(code(call(alice, "decide_batch", {decisions = {item(mine), item(mine)}})), "INVALID_ARGUMENT")
            local sibling = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(alice, "decide_batch", {decisions = {item(mine), item(sibling, 9)}})), "CONFLICT")
            test.eq(value(call(alice, "read", {approval_id = mine.approval_id})).state, "pending")
            test.eq(code(call(outsider, "decide_batch", {decisions = {item(mine)}})), "DENIED")
        end)
        test.it("serializes identical request creation and a decision racing fenced withdrawal", function()
            local workspace = "ws-races-" .. key()
            local asked = request_of(workspace)
            local first = requester:async("bee.approvals.binding:request", asked)
            local second = requester:async("bee.approvals.binding:request", asked)
            local a, b = await(first), await(second)
            local created = value(a)
            test.eq(value(b).approval_id, created.approval_id)
            test.eq((a.replayed and 1 or 0) + (b.replayed and 1 or 0), 1)
            local decision = alice:async("bee.approvals.binding:decide", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest,
                decision = "approved"})
            local withdrawal = requester:async("bee.approvals.binding:withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest})
            local decided, withdrawn = await(decision), await(withdrawal)
            local actual = value(call(requester, "read", {approval_id = created.approval_id}))
            test.eq(actual.revision, 2)
            test.eq(actual.state == "decided" or actual.state == "withdrawn", true)
            test.eq(value(withdrawn).withdrawn, actual.state == "withdrawn")
            test.eq(decided.ok, actual.state == "decided")
            local replay = call(requester, "request", asked)
            test.eq(replay.replayed, true)
            test.eq(value(replay).approval_id, created.approval_id)
        end)
        test.it("lets two eligible approvers race to one decision and reports every other outcome honestly", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            local approval_id, digest = created.approval_id, created.proposal_digest
            test.eq(code(call(outsider, "read", {approval_id = approval_id})), "DENIED")
            test.eq(value(call(alice, "read", {approval_id = approval_id})).approval_id, approval_id)
            test.eq(value(call(manager, "read", {approval_id = approval_id})).approval_id, approval_id)
            test.eq(code(call(outsider, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest})), "DENIED")
            test.eq(code(call(alice, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = string.rep("0", 64)})), "CONFLICT")
            local a = alice:async("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest})
            local b = bob:async("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = 1, decision = "denied", proposal_digest = digest})
            local wins = 0
            for _, future in ipairs({a, b}) do
                if await(future).ok then wins = wins + 1 end
            end
            test.eq(wins, 1)
            local decided = value(call(alice, "read", {approval_id = approval_id}))
            test.eq(decided.state, "decided")
            test.eq(decided.revision, 2)
            local winner, decision = decided.decider_id, decided.decision
            local winner_client = alice
            local loser_client = bob
            local loser_decision = "denied"
            if winner == BOB then
                winner_client, loser_client, loser_decision = bob, alice, "approved"
            end
            local retry = call(winner_client, "decide", {approval_id = approval_id, expected_revision = 1, decision = decision, proposal_digest = digest})
            test.eq(retry.replayed, true)
            local conflict = call(loser_client, "decide", {approval_id = approval_id, expected_revision = 1, decision = loser_decision, proposal_digest = digest})
            test.eq(code(conflict), "CONFLICT")
            test.eq(fault_value(conflict).decision, decision)
            local withdrawn = value(call(requester, "withdraw", {approval_id = approval_id, expected_revision = 1, proposal_digest = digest}))
            test.eq(withdrawn.withdrawn, false)
            test.eq((assert(bounds.object(withdrawn.request))).state, "decided")
        end)
        test.it("records one explicit confirmation and no reusable grant", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-confirm-" .. key(), {
                contract_version = 2, ttl_ms = 60000, presentation = "inline",
                proposal = {kind = "operation", ref = "bee.approvals:confirmation", revision = "1",
                    payload = {action = "close", target = {instance_id = "exact-instance"}}},
                scope = {type = "exact", parameters = {instance_id = "exact-instance"}}
            }), 1000, nil))
            local fence: {[string]: unknown} = {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest,
                decision = "allow_once", assurance = {kind = "explicit_gesture", gesture = "enter", presentation = "inline"}}
            executed(service.execute(db, ALICE, "decide", fence, 1001, nil))
            executed(service.execute(db, ALICE, "decide", fence, 1002, nil))
            local records = assert(db:query("SELECT * FROM bee_approval_decisions WHERE approval_id = ?", {created.approval_id}))
            test.eq(#records, 1)
            test.eq(assert(bounds.object(json.decode(records[1].assurance_json))).gesture, "enter")
            test.eq(#assert(db:query("SELECT * FROM bee_approval_grants WHERE approval_id = ?", {created.approval_id})), 0)
            fence.assurance = {kind = "explicit_gesture", gesture = "click", presentation = "inline"}
            test.eq(service.execute(db, ALICE, "decide", fence, 1003, nil).code, "CONFLICT")
            executed(service.execute(db, REQUESTER, "consume", {approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                owner_incarnation = created.owner_incarnation, effect_key = created.approval_id}, 1003, nil))
            executed(service.execute(db, REQUESTER, "consume", {approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                owner_incarnation = created.owner_incarnation, effect_key = created.approval_id}, 1004, nil))
            local listed = executed(service.execute(db, REQUESTER, "list", {workspace_id = created.workspace_id}, 1003, nil))
            test.eq(#assert(bounds.array(listed.requests, 64)), 1)
            db:release()
        end)
        test.it("withdraws a canceled confirmation without a decision", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-confirm-cancel-" .. key(), {
                presentation = "dialog", proposal = {kind = "operation", ref = "bee.approvals:confirmation", revision = "1", payload = {}}
            }), 1000, nil))
            executed(service.execute(db, REQUESTER, "withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}, 1001, nil))
            test.eq(#assert(db:query("SELECT * FROM bee_approval_decisions WHERE approval_id = ?", {created.approval_id})), 0)
            db:release()
        end)
        test.it("withdraws a transport origin and fences late requests without touching another transport", function()
            local db = open_test_store()
            local workspace = "origin-" .. key()
            local first = request_of(workspace, {origin = {instance_id = "transport-one"}, request_kind = "question"})
            local pending = executed(service.execute(db, REQUESTER, "request", first, 1000, nil))
            local other = executed(service.execute(db, REQUESTER, "request", request_of(workspace, {origin = {instance_id = "transport-two"}}), 1000, nil))
            local closed = executed(service.execute(db, REQUESTER, "withdraw_origin", {instance_id = "transport-one"}, 1001, nil))
            test.eq(#assert(bounds.array(closed.requests, 32)), 1)
            test.eq(executed(service.execute(db, REQUESTER, "read", {approval_id = pending.approval_id}, 1002, nil)).state, "withdrawn")
            test.eq(executed(service.execute(db, REQUESTER, "read", {approval_id = other.approval_id}, 1002, nil)).state, "pending")
            test.eq(service.execute(db, REQUESTER, "request", first, 1002, nil).replayed, true)
            first.idempotency_key = key()
            test.eq(service.execute(db, REQUESTER, "request", first, 1002, nil).code, "INVALID_STATE")
            test.eq(#assert(bounds.array(executed(service.execute(db, REQUESTER, "withdraw_origin", {instance_id = "transport-one"}, 1003, nil)).requests, 32)), 0)
            executed(service.execute(db, REQUESTER, "withdraw", {approval_id = other.approval_id, expected_revision = other.revision,
                proposal_digest = other.proposal_digest, reviewed_digest = other.reviewed_digest}, 1004, nil))
            db:release()
        end)
        test.it("closing an origin preserves expiry and a decision that already committed", function()
            local db = open_test_store()
            for _, outcome in ipairs({"expired", "decided"}) do
                local instance = "origin-race-" .. key()
                local created = executed(service.execute(db, REQUESTER, "request", request_of("origin-race-" .. key(), {
                    origin = {instance_id = instance}, ttl_ms = 10}), 1000, nil))
                if outcome == "decided" then
                    executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                        proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}, 1001, nil))
                end
                executed(service.execute(db, REQUESTER, "withdraw_origin", {instance_id = instance}, 1011, nil))
                local current = executed(service.execute(db, REQUESTER, "read", {approval_id = created.approval_id}, 1012, nil))
                test.eq(current.state, outcome)
                if outcome == "decided" then test.eq(current.decision, "approved") end
            end
            db:release()
        end)
        test.it("validates question fields and delivers every terminal answer to the requester", function()
            local db = open_test_store()
            for _, outcome in ipairs({"answer", "expired", "withdrawn"}) do
                local created = executed(service.execute(db, REQUESTER, "request", request_of("question-" .. key(), {
                    request_kind = "question", ttl_ms = 10, response_schema = {type = "object", required = {"count", "mode", "enabled"},
                        properties = {count = {type = "integer"}, mode = {enum = {"one", "two"}}, enabled = {type = "boolean"}}}}), 1000, nil))
                local decision: {[string]: unknown} = {approval_id = created.approval_id, expected_revision = 1,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "answer"}
                if outcome == "answer" then
                    for _, invalid in ipairs({{count = "2", mode = "one", enabled = false}, {count = 2, mode = "other", enabled = false}, {count = 2, mode = "one"}}) do
                        decision.response = invalid
                        test.eq(service.execute(db, ALICE, "decide", decision, 1001, nil).ok, false)
                    end
                    decision.response = {count = 2, mode = "two", enabled = false}
                    executed(service.execute(db, ALICE, "decide", decision, 1002, nil))
                    local read = executed(service.execute(db, REQUESTER, "read", {approval_id = created.approval_id}, 1003, nil))
                    test.eq(assert(bounds.object(read.response)).enabled, false)
                elseif outcome == "withdrawn" then
                    decision.decision = nil
                    executed(service.execute(db, REQUESTER, "withdraw", decision, 1002, nil))
                end
                local read = executed(service.execute(db, REQUESTER, "read", {approval_id = created.approval_id}, 1011, nil))
                test.eq(read.state, outcome == "answer" and "decided" or outcome)
                test.eq(assert(bounds.object(read.effect)).state, outcome == "answer" and "authorized" or "canceled")
                local events = assert(db:query("SELECT kind, body_json FROM bee_approval_events WHERE approval_id = ?", {created.approval_id}))
                test.ok(#events >= 2)
                if outcome == "answer" then
                    local delivered = false
                    for _, event in ipairs(events) do
                        local body = assert(bounds.object(json.decode(event.body_json)))
                        if body.state == "decided" then
                            test.eq(assert(bounds.object(body.response)).enabled, false)
                            delivered = true
                        end
                    end
                    test.is_true(delivered)
                end
            end
            db:release()
        end)
        test.it("keeps the answer on its separate decision record", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-answer-" .. key(),
                {request_kind = "question"}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, decision = "answer", response = {text = "continue"}}, 1001, nil))
            local records = assert(db:query("SELECT kind, response_json FROM bee_approval_decisions WHERE approval_id = ?", {created.approval_id}))
            test.eq(records[1].kind, "answer")
            test.eq(assert(bounds.object(json.decode(records[1].response_json))).text, "continue")
            db:release()
        end)
        test.it("fences withdrawal against the reviewed revision and digest and reports the committed race winner", function()
            local created = value(call(requester, "request", request_of("ws-withdraw-" .. key())))
            test.eq(code(call(requester, "withdraw", {approval_id = created.approval_id,
                expected_revision = 2, proposal_digest = created.proposal_digest})), "CONFLICT")
            test.eq(code(call(requester, "withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = string.rep("0", 64)})), "CONFLICT")
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            local raced = value(call(requester, "withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest}))
            test.eq(raced.withdrawn, false)
            test.eq(assert(bounds.object(raced.request)).decision, "approved")
        end)
        test.it("enforces expiry at the owner, lets only the requester withdraw and binds consumption to one effect", function()
            local workspace = "ws-" .. key()
            local short = value(call(requester, "request", request_of(workspace, {ttl_ms = 1})))
            time.sleep("5ms")
            local late = call(alice, "decide", {approval_id = short.approval_id, expected_revision = 1, decision = "approved", proposal_digest = short.proposal_digest, reviewed_digest = short.reviewed_digest})
            test.eq(code(late), "INVALID_STATE")
            test.eq(fault_value(late).state, "expired")
            local pending = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(other_requester, "withdraw", {approval_id = pending.approval_id, expected_revision = pending.revision, proposal_digest = pending.proposal_digest})), "DENIED")
            local withdrawn = value(call(requester, "withdraw", {approval_id = pending.approval_id, expected_revision = pending.revision, proposal_digest = pending.proposal_digest}))
            test.eq(withdrawn.withdrawn, true)
            test.eq((assert(bounds.object(withdrawn.request))).state, "withdrawn")
            test.eq(code(call(bob, "decide", {approval_id = pending.approval_id, expected_revision = 1, decision = "approved", proposal_digest = pending.proposal_digest, reviewed_digest = pending.reviewed_digest})), "INVALID_STATE")
            test.eq(code(call(outsider, "reconcile", {})), "DENIED")
            local store = open_test_store()
            local due = executed(service.execute(store, REQUESTER, "request", request_of(workspace, {ttl_ms = 1}), nil, requester))
            time.sleep("5ms")
            local reconciled = executed(service.execute(store, OUTBOX, "reconcile", {}, nil, nil))
            test.eq(reconciled.expired, 1)
            test.eq(executed(service.execute(store, REQUESTER, "read", {approval_id = due.approval_id}, nil, nil)).state, "expired")
            test.eq(executed(service.execute(store, OUTBOX, "reconcile", {}, nil, nil)).expired, 0)
            store:release()
            local approved = value(call(requester, "request", request_of(workspace)))
            local incarnation = approved.owner_incarnation
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation})), "INVALID_STATE")
            value(call(bob, "decide", {approval_id = approved.approval_id, expected_revision = 1, decision = "approved", proposal_digest = approved.proposal_digest, reviewed_digest = approved.reviewed_digest}))
            test.eq(code(call(other_requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation})), "DENIED")
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = string.rep("1", 64), effect_key = "launch-1", owner_incarnation = incarnation})), "CONFLICT")
            local stale = call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = assert(bounds.integer(incarnation)) + 1})
            test.eq(code(stale), "REVALIDATE")
            test.eq(fault_value(stale).consumed_effect, nil)
            local consumed = value(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation}))
            test.eq(consumed.consumed_effect, "launch-1")
            test.eq(consumed.consumer_id, REQUESTER)
            test.eq(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation}).replayed, true)
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-2", owner_incarnation = incarnation})), "CONFLICT")
            local denied = value(call(requester, "request", request_of(workspace)))
            value(call(bob, "decide", {approval_id = denied.approval_id, expected_revision = 1, decision = "denied", proposal_digest = denied.proposal_digest, reviewed_digest = denied.reviewed_digest}))
            test.eq(code(call(requester, "consume", {approval_id = denied.approval_id, proposal_digest = denied.proposal_digest, effect_key = "launch-3", owner_incarnation = incarnation})), "INVALID_STATE")
        end)
    end)
end
return test.run_cases(define_tests)
