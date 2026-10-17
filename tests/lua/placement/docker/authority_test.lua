-- SPDX-License-Identifier: MIT
-- The Docker owner checks the person's environment consent under its own declared authority.
local test = require("test")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local uuid = require("uuid")
local bounds = require("bounds")
local service = require("service")
local PERSON, POLICY = "bee.test.docker_environment_person", "docker-environment-authority-test"
local function owner(): funcs.Executor
    local entry = assert(registry.get("bee.placement.docker.service:image_owner_service"))
    local lifecycle = assert(bounds.object(assert(bounds.object(entry.data)).lifecycle))
    local declared = assert(bounds.object(lifecycle.security))
    local actor = assert(bounds.object(declared.actor))
    local policies: {security.Policy} = {}
    for _, id in ipairs(assert(bounds.ids(declared.policies))) do policies[#policies + 1] = assert(security.policy(id)) end
    return funcs.new():with_actor(security.new_actor(assert(bounds.id(actor.id)))):with_scope(security.new_scope(policies))
end
local function install_policy()
    local entry = assert(registry.get("bee.security.approvals:approver_policies"))
    local data = assert(bounds.object(entry.data))
    local rows = assert(bounds.array(data.policies, 64))
    for _, row in ipairs(rows) do if bounds.object(row) and assert(bounds.object(row)).name == POLICY then return end end
    rows[#rows + 1] = {name = POLICY, approvers = {PERSON}, max_ttl_ms = 60000, allow_permanent = true}
    data.policies = rows; entry.data = data
    local changes = registry.snapshot():changes(); assert(changes:update(entry)); assert(changes:apply())
end
local function value(raw: unknown, problem: unknown): {[string]: unknown}
    test.is_nil(problem, tostring(problem))
    local reply = assert(bounds.object(raw))
    local fault = bounds.object(reply.error)
    test.is_true(reply.ok == true, tostring(fault and fault.message))
    return assert(bounds.object(reply.value))
end
local function probe(input: {[string]: unknown}, target: string?): {[string]: unknown}
    local raw, problem = owner():call(target or "bee.tests.placement.docker:authority_probe", input)
    test.is_nil(problem, tostring(problem))
    return assert(bounds.object(raw))
end
local function approved(digest: string, workspace: string): {[string]: unknown}
    install_policy()
    local requested = value(owner():call("bee.approvals.binding:request", {workspace_id = workspace, idempotency_key = "docker-environment:" .. digest,
        request_kind = "permission", policy = POLICY,
        proposal = {kind = "operation", ref = "bee.placement.docker.binding:prepare_environment", revision = digest, input_digest = digest,
            payload = {network = "bee-coding", endpoint = "bee.gateway.api:gateway_endpoint", listener = "bee:gateway_listener", profile = "bee.placement.docker.profiles:coding"}},
        prompt = {text = "Allow the Docker environment"}}))
    local person = funcs.new():with_actor(security.new_actor(PERSON))
        :with_scope(security.new_scope({assert(security.policy("bee.security.approvals:approval_decide_policy"))}))
    value(person:call("bee.approvals.binding:decide", {approval_id = requested.approval_id, expected_revision = requested.revision,
        proposal_digest = requested.proposal_digest, reviewed_digest = requested.reviewed_digest, decision = "approved"}))
    return requested
end
local function define_tests()
    test.describe("Docker environment consent authority", function()
        test.it("consumes an approval decided before an approvals restart under the current authority", function()
            local digest, workspace = string.rep("d", 64), assert(uuid.v4())
            local requested = approved(digest, workspace)
            local db = assert(service.open())
            local restarted = assert(service.establish(db))
            db:release()
            test.is_true(restarted > assert(bounds.integer(requested.owner_incarnation)))
            local consumed = probe({approval_id = requested.approval_id, proposal_digest = requested.proposal_digest,
                owner_incarnation = requested.owner_incarnation, digest = digest}, "bee.tests.placement.docker:consume_probe")
            test.is_nil(consumed.error, tostring(consumed.error))
            local again = probe({approval_id = requested.approval_id, proposal_digest = requested.proposal_digest,
                owner_incarnation = requested.owner_incarnation, digest = digest}, "bee.tests.placement.docker:consume_probe")
            test.is_nil(again.error, tostring(again.error))
        end)
        test.it("admits the person's approved environment consent under the Docker owner's declared scope", function()
            local workspace, digest, network = assert(uuid.v4()), string.rep("b", 64), "bee-coding"
            local requested = approved(digest, workspace)
            local checked = probe({approval_id = requested.approval_id, digest = digest, network = network, workspace = workspace})
            test.is_nil(checked.error, tostring(checked.error))
            test.eq(checked.grant_id, tostring(requested.approval_id) .. ":grant")
            local other = probe({approval_id = requested.approval_id, digest = string.rep("c", 64), network = network, workspace = workspace})
            test.eq(other.error, "Docker consent grant scope differs")
        end)
    end)
end
return test.run_cases(define_tests)
