-- MIT. The approval ingress: only the approval authority appends, records
-- key on the owner's event id, a replay returns the same record, a
-- different body under a used key conflicts, and no decision is committed
-- by the thread.
local test = require("test")
local harness = require("harness")
local AUTHORITY = {"bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_lifecycle_policy", "bee:thread_approval_policy"}
local function request_body(approval_id: string): {[string]: unknown}
    return {approval_id = approval_id, request_kind = "permission", requester_id = "bee.test.requester", operation_ref = "bee.hive.telemetry:stats",
        prompt = {text = "Allow stats?"}, response_schema = {type = "object", additionalProperties = false, properties = {option = {type = "string"}}},
        expires_at = "2026-09-10T00:00:00.000Z", state = "pending"}
end
local function define_tests()
    test.describe("Thread approval ingress", function()
        local authority = harness.principal("approvals-owner", AUTHORITY)
        local member = harness.principal("member", harness.ALL)
        test.it("appends typed approval projections under the owner's event id and replays them", function()
            local thread_id = harness.thread(authority, "Approvals")
            harness.value(authority:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "member", role = "participant", expected_revision = 1}))
            local first = harness.value(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e1",
                kind = "approval.request", body = request_body("ap-1")}))
            test.eq(first.sequence, 1)
            local replay = harness.value(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e1",
                kind = "approval.request", body = request_body("ap-1")}))
            test.eq(replay.record_id, first.record_id)
            test.eq(harness.code(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e1",
                kind = "approval.request", body = request_body("ap-2")})), "CONFLICT")
            local decided = harness.value(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e2",
                kind = "approval.transition", body = {approval_id = "ap-1", expected_revision = 1, state = "approved", decider_id = "bee.test.approver", response = {text = "yes"}, reason = "approved by the owner"}}))
            test.eq(decided.sequence, 2)
            test.eq(harness.code(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e3",
                kind = "approval.transition", body = {approval_id = "ap-1", expected_revision = 1, state = "settled", reason = "no"}})), "INVALID_ARGUMENT")
            test.eq(harness.code(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e4",
                kind = "receipt", body = {scope = "action", outcome = "succeeded", evidence_refs = {}}})), "INVALID_ARGUMENT")
            test.eq(harness.code(member:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "e5",
                kind = "approval.request", body = request_body("ap-3")})), "DENIED")
            local page = harness.value(member:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"approval.request", "approval.transition"}}}))
            test.eq(#page.records, 2)
            test.eq(page.records[1].source, "bee")
            test.eq(page.records[1].body.request_kind, "permission")
            test.eq(page.records[2].body.state, "approved")
            test.eq(page.records[2].body.decider_id, "bee.test.approver")
        end)
    end)
end
return test.run_cases(define_tests)
