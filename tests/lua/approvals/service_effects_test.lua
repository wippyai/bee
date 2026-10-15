-- MIT. Approval service effects.
local test = require("test")
local events = require("events")
local bounds = require("bounds")
local time = require("time")
local service = require("service")
local worker = require("worker")
local dispatch = require("dispatch")
local fixture = require("fixture").new()
local REQUESTER = fixture.REQUESTER
local ALICE = fixture.ALICE
local OUTBOX = fixture.OUTBOX
local key = fixture.key
local scope = fixture.scope
local caller = fixture.caller
local requester = fixture.requester
local other_requester = fixture.other_requester
local alice = fixture.alice
local outsider = fixture.outsider
local call = fixture.call
local value = fixture.value
local code = fixture.code
local open_test_store = fixture.open_test_store
local executed = fixture.executed
local proposal = fixture.proposal
local request_of = fixture.request_of
local effect_wake = fixture.effect_wake
local retire_owned_effects = fixture.retire_owned_effects

local function define_tests()
    test.describe("Approval owner effects", function()
        fixture.setup("bee.tests.approvals:service_effects_db", true)
        test.after_all(retire_owned_effects)
        test.it("wakes the Gateway owner for installation when an approval decision commits", function()
            local workspace = "ws-effect-wake-" .. key()
            local created = value(call(requester, "request", request_of(workspace, {proposal = {kind = "operation", ref = "bee.hub:apply", revision = "1", payload = {}}})))
            effect_wake(assert(bounds.id(created.approval_id)), "gateway.installation", "bee.gateway.external", function()
                value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            end)
        end)
        test.it("wakes the Gateway owner for publication when an approval decision commits", function()
            local workspace = "ws-publish-wake-" .. key()
            local created = value(call(requester, "request", request_of(workspace, {proposal = {kind = "operation", ref = "bee.hub:publish", revision = "1", payload = {}}})))
            effect_wake(assert(bounds.id(created.approval_id)), "gateway.publication", "bee.gateway.external", function()
                value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            end)
        end)
        test.it("wakes the activation worker and lists an approved activation until it is consumed", function()
            local workspace = "ws-activation-" .. key()
            local activation = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "r1", payload = {source_workspace = "todo"}}
            local created = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local unrelated = value(call(requester, "request", request_of(workspace)))
            local worker = caller("bee.test.activation_worker", {"bee.security.approvals:approval_activation_effects_policy"})
            local function listed(): {[string]: boolean}
                local found: {[string]: boolean} = {}
                for _, item in ipairs(value(call(worker, "effect_queue", {destination = "gov.activation", phase = "ready", limit = 64})).effects :: {unknown}) do
                    found[tostring((item :: {[string]: unknown}).approval_id)] = true
                end
                return found
            end
            test.is_nil(listed()[tostring(created.approval_id)])
            effect_wake(assert(bounds.id(created.approval_id)), "gov.activation", "bee.gov.activation_worker", function()
                for _, request in ipairs({created, unrelated}) do
                    value(call(alice, "decide", {approval_id = request.approval_id, expected_revision = request.revision,
                        proposal_digest = request.proposal_digest, reviewed_digest = request.reviewed_digest, decision = "approved"}))
                end
            end)
            local approved = listed()
            test.is_true(approved[tostring(created.approval_id)])
            test.is_nil(approved[tostring(unrelated.approval_id)])
            local effect_id = assert(bounds.id(assert(bounds.object(created.effect)).effect_id))
            value(call(requester, "effect", {operation = "claim", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect_id, owner_incarnation = created.owner_incarnation}))
            test.is_true(listed()[tostring(created.approval_id)])
            value(call(requester, "effect", {operation = "complete", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, result = {ok = true}}))
            test.is_nil(listed()[tostring(created.approval_id)])
            test.eq(code(call(outsider, "effect_queue", {destination = "gov.activation", phase = "ready"})), "DENIED")
        end)
        test.it("lists an activation that ended without approval until its requester closes it", function()
            local workspace = "ws-closure-" .. key()
            local activation = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "r1", payload = {source_workspace = "todo"}}
            local denied = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local expired = value(call(requester, "request", request_of(workspace, {proposal = activation, ttl_ms = 1})))
            local withdrawn = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local approved = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local unrelated = value(call(requester, "request", request_of(workspace)))
            value(call(alice, "decide", {approval_id = denied.approval_id, expected_revision = denied.revision,
                proposal_digest = denied.proposal_digest, reviewed_digest = denied.reviewed_digest, decision = "denied"}))
            value(call(alice, "decide", {approval_id = approved.approval_id, expected_revision = approved.revision,
                proposal_digest = approved.proposal_digest, reviewed_digest = approved.reviewed_digest, decision = "approved"}))
            value(call(alice, "decide", {approval_id = unrelated.approval_id, expected_revision = unrelated.revision,
                proposal_digest = unrelated.proposal_digest, reviewed_digest = unrelated.reviewed_digest, decision = "denied"}))
            value(call(requester, "withdraw", {approval_id = withdrawn.approval_id, expected_revision = withdrawn.revision, proposal_digest = withdrawn.proposal_digest}))
            time.sleep("5ms")
            local store = open_test_store()
            executed(service.execute(store, OUTBOX, "reconcile", {}, nil, nil))
            store:release()
            local worker = caller("bee.test.activation_worker", {"bee.security.approvals:approval_activation_effects_policy"})
            local function listed(): {[string]: string}
                local found: {[string]: string} = {}
                for _, item in ipairs(value(call(worker, "effect_queue", {destination = "gov.activation", phase = "ended", limit = 64})).effects :: {unknown}) do
                    local row = assert(bounds.object(item))
                    found[tostring(row.approval_id)] = tostring(row.state) .. ":" .. tostring(row.decision)
                end
                return found
            end
            local ended = listed()
            test.eq(ended[tostring(denied.approval_id)], "decided:denied")
            test.eq(ended[tostring(expired.approval_id)], "expired:nil")
            test.eq(ended[tostring(withdrawn.approval_id)], "withdrawn:nil")
            test.is_nil(ended[tostring(approved.approval_id)])
            test.is_nil(ended[tostring(unrelated.approval_id)])
            test.eq(code(call(other_requester, "effect", {operation = "complete", result = {closed = true}, approval_id = denied.approval_id,
                proposal_digest = denied.proposal_digest})), "DENIED")
            test.eq(code(call(requester, "effect", {operation = "complete", result = {closed = true}, approval_id = approved.approval_id,
                proposal_digest = approved.proposal_digest})), "CONFLICT")
            value(call(requester, "effect", {operation = "complete", result = {closed = true}, approval_id = denied.approval_id, proposal_digest = denied.proposal_digest}))
            test.eq(call(requester, "effect", {operation = "complete", result = {closed = true}, approval_id = denied.approval_id,
                proposal_digest = denied.proposal_digest}).replayed, true)
            local remaining = listed()
            test.is_nil(remaining[tostring(denied.approval_id)])
            test.eq(remaining[tostring(expired.approval_id)], "expired:nil")
            test.eq(code(call(outsider, "effect_queue", {destination = "gov.activation", phase = "ended"})), "DENIED")
        end)
        test.it("routes a third-party continuation using registry metadata and fences its stable identity", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-extension-" .. key(),
                {proposal = {kind = "operation", ref = "bee.test:effect", revision = "1", payload = {}},
                    continuation = {destination = "fixture.effect", effect_id = "fixture-" .. key(), context = {target = "test"}}}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}, 1001, nil))
            local queued = executed(service.execute(db, OUTBOX, "effect_queue", {destination = "fixture.effect"}, 1002, nil))
            test.eq(#assert(bounds.array(queued.effects, 64)), 1)
            test.eq(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = "different", owner_incarnation = created.owner_incarnation}, 1003, nil).code, "CONFLICT")
            local effect = assert(bounds.object(created.effect))
            local claimed = executed(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect.effect_id, owner_incarnation = created.owner_incarnation}, 1003, nil))
            local after = assert(service.establish(db))
            local current_effect = assert(bounds.object(claimed.effect))
            local start = {operation = "start", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect.effect_id, expected_revision = current_effect.revision, owner_incarnation = after}
            test.eq(service.execute(db, REQUESTER, "effect", start, 1004, nil).code, "REVALIDATE")
            executed(service.execute(db, REQUESTER, "revalidate", {approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, owner_incarnation = after}, 1004, nil))
            local started = executed(service.execute(db, REQUESTER, "effect", start, 1005, nil))
            test.eq(assert(bounds.object(started.effect)).state, "started")
            executed(service.execute(db, REQUESTER, "effect", {operation = "complete", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect.effect_id, result = {ok = true}}, 1006, nil))
            db:release()
        end)
        test.it("fences reservations on revocation and preserves already admitted effect receipts", function()
            local db = open_test_store()
            local function allowed(): {[string]: unknown}
                local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-grant-" .. key()), 1000, nil))
                return executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id,
                    expected_revision = 1, proposal_digest = created.proposal_digest, decision = "allow_once"}, 1001, nil))
            end
            local approved = allowed()
            local contract = assert(bounds.object(approved.contract))
            local grant: {[string]: unknown} = {operation = "reserve", grant_id = tostring(approved.approval_id) .. ":grant",
                expected_revision = 1, subject = contract.subject, scope = contract.scope, effect_key = "reserved-use"}
            local reserved = executed(service.execute(db, REQUESTER, "grant", grant, 1002, nil))
            test.eq(reserved.revision, 2)
            local reservation = executed(service.execute(db,REQUESTER,"grant",{operation = "read",grant_id = grant.grant_id},1002,nil))
            test.eq(assert(bounds.object(reservation.grant)).reserved,1)
            test.eq(assert(bounds.object(reservation.grant)).used,0)
            test.eq(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = approved.approval_id,
                proposal_digest = approved.proposal_digest, effect_key = "different-use", owner_incarnation = approved.owner_incarnation}, 1003, nil).code, "CONFLICT")
            grant.operation, grant.expected_revision, grant.owner_incarnation = "admit", 1, approved.owner_incarnation
            test.eq(service.execute(db, REQUESTER, "grant", grant, 1003, nil).code, "CONFLICT")
            executed(service.execute(db, REQUESTER, "grant", {operation = "revoke", grant_id = grant.grant_id, expected_revision = 2}, 1003, nil))
            test.eq(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = approved.approval_id,
                proposal_digest = approved.proposal_digest, effect_key = "reserved-use", owner_incarnation = approved.owner_incarnation}, 1004, nil).code, "INVALID_STATE")
            local admitted = allowed()
            executed(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = admitted.approval_id,
                proposal_digest = admitted.proposal_digest, effect_key = "admitted-use", owner_incarnation = admitted.owner_incarnation}, 1002, nil))
            local revoked = executed(service.execute(db, REQUESTER, "grant", {operation = "revoke",
                grant_id = tostring(admitted.approval_id) .. ":grant", expected_revision = 2}, 1003, nil))
            test.eq(revoked.already_admitted, true)
            local receipt = {operation = "complete", approval_id = admitted.approval_id, proposal_digest = admitted.proposal_digest,
                effect_key = "admitted-use", result = {ok = true}}
            executed(service.execute(db, REQUESTER, "effect", receipt, 1004, nil))
            test.eq(service.execute(db, REQUESTER, "effect", receipt, 100000, nil).replayed, true)
            db:release()
        end)
        test.it("redelivers every terminal effect event and idempotent receipt completion stops further wakes", function()
            local db = open_test_store()
            local targets: {[string]: {[string]: unknown}} = {}
            local ids: {string} = {}
            for _, outcome in ipairs({"approved", "denied", "expired", "withdrawn", "superseded", "invalidated"}) do
                local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-dispatch-" .. key(),
                    {ttl_ms = 10, proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "1", payload = {}}}), 1000, nil))
                local id = tostring(created.approval_id)
                targets[id] = created; ids[#ids + 1] = id
                local fence: {[string]: unknown} = {approval_id = id, expected_revision = 1,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}
                if outcome == "approved" or outcome == "denied" then
                    fence.decision = outcome; executed(service.execute(db, ALICE, "decide", fence, 1005, nil))
                elseif outcome == "expired" then executed(service.execute(db, OUTBOX, "reconcile", {}, 1011, nil))
                elseif outcome == "withdrawn" then executed(service.execute(db, REQUESTER, "withdraw", fence, 1005, nil))
                else fence.outcome = outcome; executed(service.execute(db, REQUESTER, "end_request", fence, 1005, nil)) end
            end
            local deliveries: {[string]: integer} = {}
            local function send(worker_name: string, topic: string, body: {[string]: unknown}): (boolean, string?)
                test.eq(topic, service.TOPIC_WAKE)
                local id = tostring(body.approval_id)
                if targets[id] then
                    test.eq(worker_name, "bee.gov.activation_worker")
                    test.eq(body.destination, "gov.activation")
                    deliveries[id] = (deliveries[id] or 0) + 1
                end
                return true, nil
            end
            assert(dispatch.deliver(db, send))
            assert(dispatch.deliver(db, send))
            local applied = 0
            for _, id in ipairs(ids) do
                test.eq(deliveries[id], 2)
                local created = targets[id]
                local current = executed(service.execute(db, REQUESTER, "read", {approval_id = id}, 1012, nil))
                local receipt: {[string]: unknown} = {operation = "complete", approval_id = id,
                    proposal_digest = created.proposal_digest, result = {closed = true}}
                if current.decision == "approved" then
                    local claim: {[string]: unknown} = {operation = "claim", approval_id = id,
                        proposal_digest = created.proposal_digest, owner_incarnation = created.owner_incarnation,
                        effect_key = id}
                    executed(service.execute(db, REQUESTER, "effect", claim, 1012, nil))
                    test.eq(service.execute(db, REQUESTER, "effect", claim, 1012, nil).replayed, true)
                    receipt.effect_key, receipt.result = id, {ok = true}
                    applied = applied + 1
                end
                executed(service.execute(db, REQUESTER, "effect", receipt, 1013, nil))
                test.eq(service.execute(db, REQUESTER, "effect", receipt, 1014, nil).replayed, true)
                receipt.result = {different = true}
                test.eq(service.execute(db, REQUESTER, "effect", receipt, 1015, nil).code, "CONFLICT")
            end
            assert(dispatch.deliver(db, send))
            for _, id in ipairs(ids) do test.eq(deliveries[id], 2) end
            test.eq(applied, 1)
            db:release()
        end)
        test.it("durably notifies every terminal outcome without a thread and closes waiting effects", function()
            local db = open_test_store()
            local expected = {approved = "approval.decided", denied = "approval.denied", expired = "approval.expired",
                withdrawn = "approval.withdrawn", superseded = "approval.superseded", invalidated = "approval.invalidated"}
            for outcome, event_kind in pairs(expected) do
                local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-terminal-" .. key(), {ttl_ms = 10}), 1000, nil))
                local fence: {[string]: unknown} = {approval_id = created.approval_id, expected_revision = 1, proposal_digest = created.proposal_digest}
                if outcome == "approved" or outcome == "denied" then
                    fence.decision = outcome
                    executed(service.execute(db, ALICE, "decide", fence, 1005, nil))
                elseif outcome == "expired" then executed(service.execute(db, OUTBOX, "reconcile", {}, 1011, nil))
                elseif outcome == "withdrawn" then executed(service.execute(db, REQUESTER, "withdraw", fence, 1005, nil))
                else fence.outcome = outcome; executed(service.execute(db, REQUESTER, "end_request", fence, 1005, nil)) end
                local events = assert(db:query("SELECT * FROM bee_approval_events WHERE approval_id = ? ORDER BY seq", {created.approval_id}))
                test.eq(#events, 2)
                test.eq(events[2].kind, event_kind)
                test.eq(events[2].acknowledged_at, nil)
                local read = executed(service.execute(db, REQUESTER, "read", {approval_id = created.approval_id}, 1012, nil))
                test.eq(assert(bounds.object(read.effect)).state, outcome == "approved" and "authorized" or "canceled")
                executed(service.execute(db, REQUESTER, "events", {acknowledge = {events[2].event_id}}, 1013, nil))
                executed(service.execute(db, REQUESTER, "events", {acknowledge = {events[2].event_id}}, 1014, nil))
                local acknowledged = assert(db:query("SELECT acknowledged_at FROM bee_approval_events WHERE event_id = ?", {events[2].event_id}))
                test.eq(acknowledged[1].acknowledged_at ~= nil, true)
            end
            db:release()
        end)
        test.it("keeps uncertain effects queued until their receipt is reconciled", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-uncertain-" .. key(),
                {proposal = {kind = "operation", ref = "bee.test:effect", revision = "1", payload = {}},
                    continuation = {destination = "fixture.effect", effect_id = "uncertain-" .. key(), context = {}}}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}, 1001, nil))
            local effect_id = assert(bounds.object(created.effect)).effect_id
            executed(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, owner_incarnation = created.owner_incarnation}, 1002, nil))
            local receipt = {operation = "complete", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect_id, state = "uncertain", result = {ok = false, outcome = "uncertain"}}
            local uncertain = executed(service.execute(db, REQUESTER, "effect", receipt, 1003, nil))
            test.eq(uncertain.effect_completed_at, nil)
            test.eq(service.execute(db, REQUESTER, "effect", receipt, 1004, nil).replayed, true)
            local queue = executed(service.execute(db, OUTBOX, "effect_queue", {destination = "fixture.effect"}, 1004, nil))
            local found = false
            for _, raw in ipairs(assert(bounds.array(queue.effects, 64))) do
                if assert(bounds.object(raw)).approval_id == created.approval_id then found = true end
            end
            test.eq(found, true)
            local ready = executed(service.execute(db, OUTBOX, "effect_queue", {destination = "fixture.effect", phase = "ready"}, 1004, nil))
            for _, raw in ipairs(assert(bounds.array(ready.effects, 64))) do
                test.is_true(assert(bounds.object(raw)).approval_id ~= created.approval_id)
            end
            local wakes = assert(db:query("SELECT event_id FROM bee_approval_events WHERE approval_id = ? AND destination = 'fixture.effect' AND acknowledged_at IS NULL", {created.approval_id}))
            test.eq(#wakes, 0)
            receipt.state, receipt.result = "succeeded", {ok = true}
            executed(service.execute(db, REQUESTER, "effect", receipt, 1005, nil))
            test.eq(service.execute(db, REQUESTER, "effect", receipt, 1006, nil).replayed, true)
            db:release()
        end)
        test.it("separates the decision deadline from effect admission and keeps completed receipt replay", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-deadline-" .. key(),
                {ttl_ms = 10, effect_admission_ms = 2000}), 1000, requester))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}, 1005, nil))
            local claim = {approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = "deadline-effect", owner_incarnation = created.owner_incarnation}
            local consumed = executed(service.execute(db, REQUESTER, "consume", claim, 1500, nil))
            test.eq(consumed.consumed_effect, "deadline-effect")
            test.eq(service.execute(db, REQUESTER, "consume", claim, 3000, nil).replayed, true)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
