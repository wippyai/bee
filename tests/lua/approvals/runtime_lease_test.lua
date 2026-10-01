-- SPDX-License-Identifier: MIT
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local uuid = require("uuid")
local time = require("time")
local bounds = require("bounds")
local service = require("service")
local lease = require("lease")
type Object = {[string]: unknown}
local ACTOR, APPROVER, POLICY = "bee.test.runtime", "bee.test.runtime_approver", "runtime-test"
local function client(subject: string): funcs.Executor
    local policies: {security.Policy} = {}
    for _, ref in ipairs({"bee.approvals:client_test_policy", "bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy", "bee.security.approvals:approval_decide_policy"}) do
        policies[#policies + 1] = assert(security.policy(ref))
    end
    return assert(funcs.new():with_actor(assert(security.new_actor(subject))):with_scope(security.new_scope(policies)))
end
local function call(subject: string, operation: string, input: Object): Object
    local raw, err = client(subject):call("bee.approvals.binding:" .. operation, input)
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end
local function value(reply: Object): Object
    if reply.ok ~= true then error(tostring(assert(bounds.object(reply.error)).message)) end
    return assert(bounds.object(reply.value))
end
local function install()
    local entry = assert(registry.get("bee:approver_policies"))
    local data = assert(bounds.object(entry.data))
    local policies = assert(bounds.array(data.policies, 64))
    for _, raw in ipairs(policies) do if assert(bounds.object(raw)).name == POLICY then return end end
    policies[#policies + 1] = {name = POLICY, approvers = {APPROVER}, max_ttl_ms = 60000}
    data.policies = policies; entry.data = data
    local changes = registry.snapshot():changes()
    assert(changes:update(entry)); assert(changes:apply())
end
local function create(workspace: string, expires: integer, uses: integer): Object
    return value(call(ACTOR, "request", {workspace_id = workspace, idempotency_key = assert(uuid.v4()), request_kind = "permission", policy = POLICY,
        proposal = {kind = "operation", ref = lease.REF, revision = "1", payload = {subject = ACTOR, workspace_id = workspace,
            tool = "Bash", input_digest = string.rep("a", 64), expires_ms = expires, max_uses = uses}}, prompt = {text = "Allow this bounded runtime lease?"}}))
end
local function grant(approval: Object): Object
    value(call(APPROVER, "decide", {approval_id = approval.approval_id, expected_revision = approval.revision,
        proposal_digest = approval.proposal_digest, decision = "approved"}))
    return value(call(ACTOR, "runtime_lease", {operation = "grant", lease_ref = approval.approval_id}))
end
local function define_tests()
    test.describe("Approvals runtime lease authority", function()
        test.it("binds subject, exact input, bounded uses and idempotent effects across restart", function()
            install()
            local now = math.floor(time.now():unix_nano() / 1000000)
            local workspace = "runtime-lease-" .. assert(uuid.v4())
            local approval = create(workspace, now + 60000, 1)
            test.eq(call(ACTOR, "runtime_lease", {operation = "grant", lease_ref = approval.approval_id}).ok, false)
            local granted = grant(approval)
            test.eq(granted.lease_ref, approval.approval_id)
            test.eq(call(ACTOR, "runtime_lease", {operation = "check", lease_ref = approval.approval_id, workspace_id = workspace}).ok, true)
            local request: Object = {operation = "use", lease_ref = approval.approval_id, workspace_id = workspace,
                tool = "Bash", input_digest = string.rep("a", 64), effect_key = "effect-1"}
            test.eq(call("other", "runtime_lease", request).ok, false)
            request.tool = "Write"; test.eq(call(ACTOR, "runtime_lease", request).ok, false); request.tool = "Bash"
            request.input_digest = string.rep("b", 64); test.eq(call(ACTOR, "runtime_lease", request).ok, false); request.input_digest = string.rep("a", 64)
            test.eq(value(call(ACTOR, "runtime_lease", request)).consumed, true)
            test.eq(call(ACTOR, "runtime_lease", {operation = "check", lease_ref = approval.approval_id, workspace_id = workspace}).ok, false)
            local db = assert(service.open()); assert(service.establish(db)); db:release()
            test.eq(call(ACTOR, "runtime_lease", request).replayed, true)
            request.effect_key = "effect-2"; test.eq(call(ACTOR, "runtime_lease", request).ok, false)
            value(call(ACTOR, "runtime_lease", {operation = "revoke", lease_ref = approval.approval_id}))
            request.effect_key = "effect-1"; test.eq(call(ACTOR, "runtime_lease", request).ok, false)
        end)
        test.it("rejects expired and foreign lease ceilings before approval", function()
            install()
            local now = math.floor(time.now():unix_nano() / 1000000)
            local payload: Object = {subject = "other", workspace_id = "ws", tool = "Bash", input_digest = string.rep("a", 64), expires_ms = now + 60000, max_uses = 1}
            local request: Object = {workspace_id = "ws", idempotency_key = assert(uuid.v4()), request_kind = "permission", policy = POLICY,
                proposal = {kind = "operation", ref = lease.REF, revision = "1", payload = payload}, prompt = {text = "Lease"}}
            test.eq(call(ACTOR, "request", request).ok, false)
            payload.subject = ACTOR; payload.expires_ms = now - 1
            test.eq(call(ACTOR, "request", request).ok, false)
            payload.expires_ms = now + 2678400000
            test.eq(call(ACTOR, "request", request).ok, false)
        end)
    end)
end
return test.run_cases(define_tests)
