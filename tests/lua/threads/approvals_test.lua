-- MIT. The approval ingress: only the approval authority appends, records
-- key on the owner's event id, a replay returns the same record, a
-- different body under a used key conflicts, and no decision is committed
-- by the thread. Its notices owe their recipient a delivery and never an
-- answer.
local test = require("test")
local harness = require("harness")
local AUTHORITY = {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_approval_policy"}
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
        test.it("addresses a notice to a member and owes the delivery exactly once", function()
            local thread_id = harness.thread(authority, "Approvals")
            harness.value(authority:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "member", role = "participant", expected_revision = 1}))
            local notice: {[string]: unknown} = {message_id = "ap-9:2:notice", message_kind = "notification", recipient_ids = {"member"},
                content = {text = "Approval ap-9 is approved."}}
            local first = harness.value(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n1",
                kind = "message", body = notice}))
            local replay = harness.value(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n1",
                kind = "message", body = notice}))
            test.eq(replay.record_id, first.record_id)
            local page = harness.value(member:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#page.records, 1)
            test.eq(page.records[1].body.sender_id, "approvals-owner")
            -- A replayed projection commits nothing, so the recipient still
            -- owes exactly one delivery for it.
            local claimed = harness.value(member:call("claim", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "inbox", limit = 4}))
            test.eq(#claimed.deliveries, 1)
            test.eq(claimed.deliveries[1].message_id, "ap-9:2:notice")
            -- Nothing appended here may owe an answer: this ingress holds no
            -- membership, so nobody could ever be held to one.
            test.eq(harness.code(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n2", kind = "message",
                body = {message_id = "ap-9:3", message_kind = "request", recipient_ids = {"member"}, content = {text = "Answer me."}}})), "INVALID_ARGUMENT")
            test.eq(harness.code(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n3", kind = "message",
                body = {message_id = "ap-9:4:notice", message_kind = "notification", recipient_ids = {}, content = {text = "To nobody."}}})), "INVALID_ARGUMENT")
            test.eq(harness.code(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n4", kind = "message",
                body = {message_id = "ap-9:5:notice", message_kind = "notification", sender_id = "member", recipient_ids = {"member"}, content = {text = "Not mine."}}})), "INVALID_ARGUMENT")
            test.eq(harness.code(member:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n5",
                kind = "message", body = notice})), "DENIED")
        end)
        test.it("records a notice to a departed recipient without owing an undeliverable obligation", function()
            local thread_id = harness.thread(authority, "Approvals")
            harness.value(authority:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "member", role = "participant", expected_revision = 1}))
            -- The requester leaves before the decision is projected. Only an
            -- active member can ever claim an obligation, so no obligation may
            -- outlive the membership that could have settled it.
            harness.value(authority:call("leave", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "member", expected_revision = 2}))
            local notice: {[string]: unknown} = {message_id = "ap-7:2:notice", message_kind = "notification", recipient_ids = {"member"},
                content = {text = "Approval ap-7 is denied."}}
            harness.value(authority:call("approval_append", {thread_id = thread_id, idempotency_key = harness.key(), owner_event_id = "n6", kind = "message", body = notice}))
            -- The notice is still recorded: the outcome is not withheld from the thread.
            local page = harness.value(authority:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#page.records, 1)
            local recipients = (page.records[1].body :: {[string]: unknown}).recipient_ids
            test.eq((recipients :: {string})[1], "member")
            -- But nothing owes a delivery to someone who can no longer be held to one.
            local db = harness.open()
            local rows = harness.query(db, "SELECT recipient_id FROM bee_thread_obligations WHERE thread_id = ?", {thread_id})
            db:release()
            test.eq(#rows, 0)
        end)
    end)
end
return test.run_cases(define_tests)
