-- MIT. A selected plan is bound to the existing Approvals protocol exactly.
local test = require("test")
local approval = require("approval")
local canonical = require("canonical")
local hash = require("hash")

local DIGEST = string.rep("a", 64)
local function plan(): {[string]: unknown}
    return {workspace_id = "workspace-a", source_node = "source-a", source_workspace = "application-a",
        version = "v1", revision = 3, plan_digest = DIGEST,
        artifact_digest = string.rep("b", 64), preflight_digest = string.rep("c", 64)}
end

local function executor(change: boolean?): approval.Executor
    local selected = {}
    function selected:call(method: string, request: unknown): (unknown?, unknown?)
        local value = request :: {[string]: unknown}
        if method == "bee.approvals:request" then
            local proposal = value.proposal :: {[string]: unknown}
            if change then proposal = {kind = "operation", ref = "other", revision = "other", payload = {}} end
            local bytes = assert(canonical.encode(proposal))
            local digest = assert(hash.sha256(bytes))
            return {ok = true, replayed = false, value = {approval_id = "approval-1",
                proposal = proposal, proposal_digest = digest, owner_incarnation = 7}}, nil
        end
        if method == "bee.approvals:revalidate" then
            return {ok = true, replayed = false, value = {approval_id = value.approval_id,
                proposal_digest = value.proposal_digest, validated_incarnation = value.owner_incarnation}}, nil
        end
        return {ok = true, replayed = false, value = {approval_id = value.approval_id,
            proposal_digest = value.proposal_digest, consumer_id = "governance-host",
            consumed_effect = value.effect_key}}, nil
    end
    return selected :: approval.Executor
end

local function define_tests()
    test.describe("Governance approval bridge", function()
        test.it("requests and consumes an exact plan without gaining decision authority", function()
            local item = plan()
            local bound, err = approval.request(executor(), item, "user-approval", "request-1")
            if not bound then error(tostring(err)) end
            test.eq(bound.approval_plan_digest, DIGEST)
            test.eq(bound.owner_incarnation, 7)
            item.approval_id = bound.approval_id
            item.approval_proposal_digest = bound.approval_proposal_digest
            item.approval_owner_incarnation = bound.owner_incarnation
            local consumed, consume_error = approval.consume(executor(), item, "apply-v1")
            if not consumed then error(tostring(consume_error)) end
            test.eq(consumed.consumed_effect, "apply-v1")
        end)

        test.it("refuses a reply for another proposal", function()
            local bound = approval.request(executor(true), plan(), "user-approval", "request-2")
            test.is_true(bound == nil)
        end)

        test.it("binds activation and validates the exact consumption receipt", function()
            local intent = {workspace_id = "workspace-a", overlay_owner = "bee.governance:overlay",
                source_node = "source-a", source_workspace = "application-a", version = "v1",
                authorization_digest = DIGEST, artifact_digest = string.rep("b", 64),
                resolution_digest = string.rep("c", 64), preflight_digest = string.rep("d", 64),
                application_admission_digest = string.rep("f", 64),
                effect_key = string.rep("e", 64)}
            local bound, bind_error = approval.request_activation(executor(), intent, "user-approval", "activation-1")
            if not bound then error(tostring(bind_error)) end
            intent.approval_id, intent.approval_proposal_digest = bound.approval_id, bound.approval_proposal_digest
            intent.approval_owner_incarnation = bound.owner_incarnation
            local consumed, consume_error = approval.consume_activation(executor(), intent, "governance-host")
            if not consumed then error(tostring(consume_error and consume_error.message)) end
            test.eq(consumed.consumed_effect, intent.effect_key)
            local proposal = assert(approval.activation_proposal(intent))
            test.eq(((proposal.payload :: {[string]: unknown}).application_admission_digest), string.rep("f", 64))
            local wrong, wrong_error = approval.consume_activation(executor(), intent, "other-host")
            test.is_nil(wrong)
            test.eq(wrong_error and wrong_error.code, "CONFLICT")
            local stale = {}
            function stale:call(_method: string, _request: unknown): (unknown?, unknown?)
                return {ok = false, error = {code = "REVALIDATE", message = "authority changed"},
                    value = {current_incarnation = 9}}, nil
            end
            local stale_result, stale_error = approval.consume_activation(stale :: approval.Executor, intent, "governance-host")
            test.is_nil(stale_result)
            test.eq(stale_error and stale_error.code, "REVALIDATE")
            test.eq(stale_error and stale_error.value and stale_error.value.current_incarnation, 9)
            local validated, validation_error = approval.revalidate_activation(executor(), intent, 9)
            if not validated then error(tostring(validation_error and validation_error.message)) end
            test.eq(validated.validated_incarnation, 9)
        end)
    end)
end

return test.run_cases(define_tests)
