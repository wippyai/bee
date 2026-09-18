-- MIT. Focused tests for the pure destination-plan request decoder.
local test = require("test")
local protocol = require("plan_protocol")

local DIGEST = string.rep("a", 64)
local function blob(bytes: string): {[string]: string}
    return {bytes = bytes, digest = DIGEST}
end

local function define_tests()
    test.describe("Governance destination plan protocol", function()
        test.it("decodes a bounded stage and keeps exact byte strings", function()
            local request = assert(protocol.decode({operation = "stage", version = "v1",
                source_node = "node-a", source_workspace = "workspace-a", expected_revision = 0,
                idempotency_key = "receive-1", candidate = blob("candidate\0bytes"),
                artifact = blob("artifact"), preflight = blob("preflight") }))
            test.eq(request.operation, "stage")
            test.eq(request.candidate.bytes, "candidate\0bytes")
            test.eq(request.source_workspace, "workspace-a")
        end)
        test.it("accepts only an explicit local review status", function()
            local accepted = assert(protocol.decode({operation = "record_review", version = "v1",
                source_node = "node-a", source_workspace = "workspace-a", expected_revision = 1,
                idempotency_key = "review-1", review_status = "accepted", review_reason = "checked"}))
            test.eq(accepted.review_status, "accepted")
            test.is_nil(protocol.decode({operation = "record_review", version = "v1",
                source_node = "node-a", source_workspace = "workspace-a", expected_revision = 1,
                idempotency_key = "review-2", decision = "approved"}))
            test.is_nil(protocol.decode({operation = "record_review", version = "v1",
                source_node = "node-a", source_workspace = "workspace-a", expected_revision = 1,
                idempotency_key = "review-3", review_status = "accepted", extra = true}))
        end)
        test.it("requires source-qualified identities and exact approval binding", function()
            local binding = assert(protocol.decode({operation = "bind_approval", version = "v1",
                source_node = "node-a", source_workspace = "workspace-a", expected_revision = 2,
                idempotency_key = "bind-1", approval_id = "approval-1",
                approval_plan_digest = DIGEST, approval_proposal_digest = string.rep("b", 64),
                approval_owner_incarnation = 7}))
            test.eq(binding.approval_plan_digest, DIGEST)
            test.eq(binding.approval_proposal_digest, string.rep("b", 64))
            test.eq(binding.approval_owner_incarnation, 7)
            test.is_nil(protocol.decode({operation = "get", version = "v1"}))
            test.is_nil(protocol.decode({operation = "select", version = "v1", source_node = "node-a",
                source_workspace = "workspace-a", expected_revision = 2, idempotency_key = "select-1",
                auto = true}))
        end)
    end)
end

return test.run_cases(define_tests)
