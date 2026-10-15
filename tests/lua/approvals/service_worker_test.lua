-- MIT. Approval service worker.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local registry = require("registry")
local process = require("process")
local service = require("service")
local worker = require("worker")
local outbox = require("outbox")
local thread_harness = require("thread_harness")
local fixture = require("fixture").new()
local REQUESTER = fixture.REQUESTER
local ALICE = fixture.ALICE
local key = fixture.key
local requester = fixture.requester
local launcher = fixture.launcher
local stranger = fixture.stranger
local alice = fixture.alice
local outsider = fixture.outsider
local manager = fixture.manager
local owner = fixture.owner
local call = fixture.call
local value = fixture.value
local code = fixture.code
local open_test_store = fixture.open_test_store
local executed = fixture.executed
local proposal = fixture.proposal
local attempt_proposal = fixture.attempt_proposal
local request_of = fixture.request_of
local thread = fixture.thread
local thread_records = fixture.thread_records
local until_records = fixture.until_records
local until_notices = fixture.until_notices
local retire_owned_effects = fixture.retire_owned_effects

local function define_tests()
    test.describe("Approval owner worker", function()
        fixture.setup("bee.tests.approvals:service_worker_db", true)
        test.after_all(retire_owned_effects)
        test.it("projects requests and decisions onto the thread through the worker exactly once", function()
            local workspace = "ws-" .. key()
            local thread_id = thread_harness.thread(launcher, "Approvals")
            thread_harness.value(launcher:call("admit_action", {thread_id = thread_id, idempotency_key = key(), action_id = "a1", admitted = thread_harness.admitted()}))
            thread_harness.value(launcher:call("prepare_attempt", {thread_id = thread_id, idempotency_key = key(), action_id = "a1", attempt_id = "t1", prepared = thread_harness.prepared()}))
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal(nil, "t1")}))), "INVALID_ARGUMENT")
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a1", "t9")}))), "INVALID_ARGUMENT")
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a9", "t1")}))), "INVALID_ARGUMENT")
            local created = value(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a1", "t1")})))
            local binding = assert(bounds.object(created.binding))
            test.eq(binding.attempt_id, "t1")
            test.eq(binding.record_id ~= nil, true)
            local approval_id = created.approval_id
            local rows = principals.objects(value(call(requester, "deliveries", {approval_id = approval_id})).deliveries)
            test.eq(#rows, 1)
            test.eq(rows[1].event_id, approval_id .. ":1")
            local records = until_records(thread_id, 1)
            test.eq(#records, 1)
            test.eq(records[1].kind, "approval.request")
            test.eq(records[1].attempt_id, "t1")
            test.eq((assert(bounds.object(records[1].body))).requester_id, REQUESTER)
            value(call(alice, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, response = {text = "go"}}))
            records = until_records(thread_id, 2)
            if #records ~= 2 then
                local pendings = principals.objects(value(call(requester, "deliveries", {approval_id = approval_id})).deliveries)
                error("transition not delivered: " .. tostring(pendings[2] and pendings[2].last_error) .. " attempts " .. tostring(pendings[2] and pendings[2].attempts))
            end
            local body = assert(bounds.object(records[2].body))
            test.eq(body.state, "approved")
            test.eq(body.decider_id, ALICE)
            test.eq(body.expected_revision, 1)
            test.eq((assert(bounds.object(body.response))).text, "go")
            -- The transition record owes nobody anything, so the outcome is
            -- also addressed to the requester: the obligation it creates is
            -- what the delivery layer carries to the waiting agent.
            local notices = until_notices(thread_id, 1)
            test.eq(#notices, 1)
            local acked = principals.objects(value(call(requester, "deliveries", {approval_id = approval_id})).deliveries)
            test.eq(#acked, 3)
            test.eq(acked[2].acknowledged_at ~= nil, true)
            test.eq(acked[3].event_id, approval_id .. ":2:notice")
            test.eq(acked[3].kind, "message")
            test.eq(code(call(requester, "deliveries", {approval_id = approval_id, redeliver = approval_id .. ":2"})), "DENIED")
            test.eq(code(call(manager, "deliveries", {approval_id = approval_id, redeliver = approval_id .. ":2"})), "INVALID_STATE")
            test.eq(#thread_records(thread_id), 2)
            local notice = assert(bounds.object(notices[1].body))
            test.eq(notice.message_kind, "notification")
            test.eq(notice.sender_id, service.WORKER_NAME)
            test.eq((principals.strings(notice.recipient_ids))[1], REQUESTER)
            test.eq((assert(bounds.object(notice.content))).text, "Approval " .. approval_id .. " is approved.")
            local claimed = thread_harness.value(launcher:call("claim", {thread_id = thread_id, idempotency_key = key(), consumer_id = "inbox", limit = 4}))
            local pending = principals.objects(claimed.deliveries)
            test.eq(#pending, 1)
            test.eq(pending[1].message_id, notice.message_id)
            -- A refusal is announced on the same path: what leaves an agent
            -- waiting is the silence, not the answer.
            local refused = value(call(requester, "request", request_of(workspace, {thread_id = thread_id})))
            local refused_id = refused.approval_id
            value(call(alice, "decide", {approval_id = refused_id, expected_revision = 1, decision = "denied", proposal_digest = refused.proposal_digest, reviewed_digest = refused.reviewed_digest}))
            local both = until_notices(thread_id, 2)
            test.eq(#both, 2)
            local denial = assert(bounds.object(both[2].body))
            test.eq((assert(bounds.object(denial.content))).text, "Approval " .. refused_id .. " is denied.")
        end)
        test.it("survives a crash between the thread commit and the outbox acknowledgement without a duplicate record", function()
            local workspace = "ws-" .. key()
            local thread_id = thread()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = thread_id}), nil, requester))
            test.eq((assert(bounds.object(created.binding))).role, "owner")
            local approval_id = created.approval_id
            local honest = outbox.thread_sender(owner)
            local sent = 0
            local report = assert(outbox.drain(db, "holder", function(delivery): (boolean, string?)
                sent = sent + 1
                local ok, err = honest(delivery)
                if not ok then return false, err end
                return false, "transport lost before acknowledgement"
            end))
            test.eq(report.claimed, 1)
            test.eq(report.failed, 1)
            test.eq(sent, 1)
            test.eq(#thread_records(thread_id), 1)
            local unacked = assert(outbox.deliveries(db, approval_id))[1]
            test.eq(unacked.attempts, 1)
            test.eq(unacked.acknowledged_at, nil)
            test.eq(unacked.last_error, "transport lost before acknowledgement")
            local idle = assert(outbox.drain(db, "holder", honest))
            test.eq(idle.claimed, 0)
            local _, reset_error = db:execute("UPDATE bee_approval_outbox SET next_attempt_ms = 0 WHERE event_id = ?", {approval_id .. ":1"})
            test.eq(reset_error, nil)
            local again = assert(outbox.drain(db, "holder", honest))
            test.eq(again.delivered, 1)
            local records = thread_records(thread_id)
            test.eq(#records, 1)
            test.eq(records[1].kind, "approval.request")
            local acked = assert(outbox.deliveries(db, approval_id))[1]
            test.eq(acked.acknowledged_at ~= nil, true)
            local repeated = assert(outbox.drain(db, "holder", honest))
            test.eq(repeated.claimed, 0)
            test.eq(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = "thread-missing"}), nil, requester).code, "NOT_FOUND")
            local foreign = thread_harness.thread(stranger, "Foreign")
            test.eq(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = foreign}), nil, requester).code, "DENIED")
            local later = executed(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = thread_id}), nil, requester))
            local delivered_later = assert(outbox.drain(db, "holder", honest))
            test.eq(delivered_later.delivered, 1)
            test.eq(#thread_records(thread_id), 2)
            db:release()
        end)
        test.it("runs the owner worker under its own actor", function()
            local pid = process.registry.lookup(service.WORKER_NAME)
            test.eq(pid ~= nil, true)
            local capabilities = value(call(outsider, "capabilities", {}))
            test.eq(capabilities.projection, "thread_outbox_at_least_once")
            test.eq(capabilities.expiry, "owner_reconcile")
            test.eq(capabilities.dedupe_horizon, "retention_after_expiry")
        end)
        test.it("keeps reconciliation and outbox drain failures diagnosable", function()
            local reconcile_error = worker.run_pass(function(): service.Reply
                return {ok = false, error = {code = "STORAGE", message = "authority store is corrupt"}, value = nil, replayed = false}
            end, function(): string?
                error("drain must not run after reconciliation fails")
            end)
            test.eq(reconcile_error, "STORAGE: authority store is corrupt")
            local drain_error = worker.run_pass(function(): service.Reply
                return {ok = true, error = nil, value = nil, replayed = false}
            end, function(): string?
                return "database busy"
            end)
            test.eq(drain_error, "drain approval outbox: database busy")
        end)
    end)
end
return test.run_cases(define_tests)
