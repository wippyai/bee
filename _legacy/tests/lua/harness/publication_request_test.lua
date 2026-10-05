-- MIT. Agent publication requests end to end through the approval owner:
-- an attempt files one approval for sealed pack bytes, the person decides
-- it, and only an approved request is uploaded by the owner worker without
-- any status poll. The Hub facade is a recorded fixture; the approvals
-- owner, thread binding and gateway authority are the real ones.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local publish = require("publish")
local publishing = require("publishing")
local AGENT = "bee.test.publish_agent"
local OTHER = "bee.test.publish_other"
local APPROVER = "bee.test.publish_approver"
local APPROVER_POLICY = "publication-fixture"
local CONFIGURATION = "bee.gateway.env:module_publication"
local PACK = string.rep("a", 64)
local base_port = publish.port
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:installation_client_policy", "bee.security.gateway:gateway_manage_policy",
    "bee.security.gateway:gateway_admit_policy", "bee.security.threads:thread_create_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_observe_policy",
    "bee.harness.catalog:approver_client_policy", "bee.security.approvals:approval_decide_policy",
    "bee.security.approvals:approval_consume_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function raw_call(actor_id: string, workspace: string, target: string, request: unknown): Object
    local result, err = funcs.new():with_actor(principals.actor(actor_id, workspace)):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return assert(bounds.object(result))
end
local function call(actor_id: string, workspace: string, target: string, request: unknown): Object
    local reply = raw_call(actor_id, workspace, target, request)
    if not reply.ok then
        local fault = assert(bounds.object(reply.error))
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end
local function apply(entry: Object)
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply " .. tostring(entry.id) .. ": " .. tostring(err)) end
end
local function endpoint(): string
    local entry = registry.get("bee.gateway.api:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((assert(bounds.object(entry.data))).address)
end
local function ensure_approver_policy(name: string)
    local policies_entry = registry.get("bee.security.approvals:approver_policies")
    if not policies_entry then error("approver policies entry") end
    local list_owner = assert(bounds.object(policies_entry.data))
    local list = principals.objects(list_owner.policies)
    list_owner.policies = list
    for _, item in ipairs(list) do
        if item.name == name then return end
    end
    list[#list + 1] = {name = name, approvers = {APPROVER}, max_ttl_ms = 60000}
    apply(policies_entry)
end
local function select_policy(name: string): string
    local entry = registry.get(CONFIGURATION)
    if not entry then error("module publication configuration") end
    local data = assert(bounds.object(entry.data))
    local previous = tostring(data.approval_policy)
    data.approval_policy = name
    apply(entry)
    return previous
end
-- One admitted attempt with its gateway binding, as the carrier admits it.
local function attempt(workspace: string): Binding
    local thread = call(AGENT, workspace, "bee.threads.binding:create",
        {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Publication"}).thread_id
    local attempt_id = fresh("attempt")
    local action = "action-" .. attempt_id
    call(AGENT, workspace, "bee.threads.binding:admit_action", {thread_id = thread, action_id = action,
        idempotency_key = fresh("admit"), admitted = {request_id = fresh("req"), principal_id = AGENT, binding_ref = "test-binding",
            binding_digest = "test-digest", grant_refs = {}, budget_ref = "test-budget", input = {text = "publish"}}})
    call(AGENT, workspace, "bee.threads.binding:prepare_attempt", {thread_id = thread, action_id = action,
        attempt_id = attempt_id, idempotency_key = fresh("prepare"), prepared = {binding_ref = "test-binding", binding_digest = "test-digest",
            profile_id = "test-profile", profile_digest = "test-profile-digest", placement_binding = "test-placement",
            placement_attempt_id = attempt_id, plan_digest = "test-plan"}})
    local tools = {"publish_request", "publish_status"}
    local admitted = call(AGENT, workspace, "bee.gateway.binding:admit", {subject = AGENT, action_id = action,
        attempt_id = attempt_id, thread_id = thread, owner_incarnation = 1, carrier_epoch = 1, tools = tools,
        ttl_ms = 600000, idempotency_key = fresh("admit"), workspace_id = workspace,
        surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}})
    local binding_id = (assert(bounds.object(admitted.binding))).binding_id
    assert(type(binding_id) == "string" and type(thread) == "string")
    return {binding_id = binding_id, subject = AGENT, action_id = action, attempt_id = attempt_id,
        thread_id = thread, workspace_id = workspace}
end
local function measured(): Object
    local staged: Object = {component = "bee/publish-probe", version = "0.0.1-probe.1",
        digest = PACK, visibility = "private", organization = "bee", source = "/home/person/work/probe"}
    local plan_digest = publishing.plan_digest(staged)
    if not plan_digest then error("measure staged publication") end
    staged.plan_digest = plan_digest
    return staged
end
-- The Hub facade fixture: one sealed pack and a recorded upload.
type Hub = {calls: {Object}, applies: {Object}, apply_reply: Object}
local function hub(apply_reply: Object?): Hub
    return {calls = {}, applies = {}, apply_reply = apply_reply or {ok = true, replayed = false,
        value = {state = "published", message = "Publication completed"}}}
end
local function port(binding: Binding, fixture: Hub): publish.Port
    local selected = base_port(binding)
    selected.hub = function(value: Object, manage: boolean): Object
        fixture.calls[#fixture.calls + 1] = {operation = value.operation, manage = manage}
        if value.operation == "publish_request" then
            return {ok = true, replayed = false, value = measured()}
        end
        if value.operation == "publish_apply" then
            if not manage then return {ok = false, replayed = false, code = "DENIED", message = "Hub operation is not authorized"} end
            local expected = tostring(value.expected_digest or "")
            fixture.applies[#fixture.applies + 1] = {request = value.request, expected_digest = expected}
            return fixture.apply_reply
        end
        return {ok = false, replayed = false, code = "INVALID", message = "unexpected Hub operation"}
    end
    return selected
end
local function drain(fixture: Hub): (integer, string?)
    local original_port = publish.port
    local drained: integer = 0
    local drain_error: string? = nil
    publish.port = function(worker_binding: Binding): publish.Port
        return port(worker_binding, fixture)
    end
    local ok, failure = pcall(function()
        drained, drain_error = publish.drain_approved()
    end)
    publish.port = original_port
    if not ok then error(failure) end
    return drained, drain_error
end
local function value_of(reply: Object): Object
    if not reply.ok then
        local fault = assert(bounds.object(reply.error))
        error(tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end
local function define_tests()
    test.describe("Agent publication requests", function()
        test.it("uploads an approved pack through the owner worker without any status poll", function()
            ensure_approver_policy(APPROVER_POLICY)
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("publish")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub()
                local selected = port(binding, fixture)
                local filed = value_of(publish.request(selected, binding, APPROVER_POLICY,
                    {component = "bee/publish-probe", version = "0.0.1-probe.1",
                        visibility = "private", source = "/home/person/work/probe"}))
                test.eq(filed.status, "pending")
                test.eq(filed.component, "bee/publish-probe")
                test.eq(filed.version, "0.0.1-probe.1")
                test.eq(filed.digest, PACK)
                local request_id = filed.request_id
                local plan_digest = tostring(filed.plan_digest)
                local pending = value_of(publish.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(pending.status, "pending")
                test.eq(#fixture.applies, 0)
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(read.requester_id, AGENT)
                test.eq(read.thread_id, binding.thread_id)
                test.eq((assert(bounds.object(read.prompt))).text, "Publish bee/publish-probe 0.0.1-probe.1 (private)?")
                local payload = assert(bounds.object((assert(bounds.object(read.proposal))).payload))
                test.eq(payload.digest, PACK)
                test.eq(payload.plan_digest, plan_digest)
                test.eq(payload.binding_id, binding.binding_id)
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local uploading = value_of(publish.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(uploading.status, "approved")
                test.eq(#fixture.applies, 0)
                local drained, drain_error = drain(fixture)
                test.is_nil(drain_error)
                test.eq(drained, 1)
                test.eq(#fixture.applies, 1)
                test.eq(fixture.applies[1].expected_digest, plan_digest)
                local consumed = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(consumed.consumer_id, AGENT)
                test.eq(consumed.consumed_effect, "hub-publish:" .. request_id)
                test.not_nil(consumed.effect_completed_at)
                local applied = value_of(publish.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(applied.status, "applied")
                test.eq(#fixture.applies, 1)
                local drained_again, drain_again_error = publish.drain_approved()
                test.is_nil(drain_again_error)
                test.eq(drained_again, 0)
                local other = attempt(workspace)
                local foreign = publish.status(port(other, hub()), other, APPROVER_POLICY, {request_id = request_id})
                test.is_false(foreign.ok)
                test.eq(foreign.error and foreign.error.code, "DENIED")
            end)
            select_policy(previous)
            if not ok then error(failure) end
        end)

        test.it("reports a failed upload with the Hub code", function()
            ensure_approver_policy(APPROVER_POLICY)
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("publish-failed")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub({ok = false, replayed = false, code = "FAILED",
                    message = "uploader refused publication (exit 1): version exists"})
                local selected = port(binding, fixture)
                local filed = value_of(publish.request(selected, binding, APPROVER_POLICY,
                    {component = "bee/publish-probe", version = "0.0.1-probe.1",
                        visibility = "private", source = "/home/person/work/probe"}))
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = filed.request_id})
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = filed.request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local drained, drain_error = drain(fixture)
                test.is_nil(drain_error)
                test.eq(drained, 1)
                local failed = value_of(publish.status(selected, binding, APPROVER_POLICY, {request_id = filed.request_id}))
                test.eq(failed.status, "failed")
                test.eq(failed.code, "FAILED")
                local completed = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = filed.request_id})
                test.not_nil(completed.effect_completed_at)
                local drained_again, drain_again_error = publish.drain_approved()
                test.is_nil(drain_again_error)
                test.eq(drained_again, 0)
            end)
            select_policy(previous)
            if not ok then error(failure) end
        end)

        test.it("refuses a caller that is not the bound subject and a host without a publication link", function()
            local workspace = fresh("publish-denied")
            call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
            local binding = attempt(workspace)
            local foreign = raw_call(OTHER, workspace, "bee.gateway.binding:publish_request",
                {binding_id = binding.binding_id, component = "bee/publish-probe",
                    version = "0.0.1-probe.1", visibility = "private", source = "/home/person/work/probe"})
            test.is_false(foreign.ok)
            test.eq((assert(bounds.object(foreign.error))).code, "DENIED")
            local reference = registry.get(publish.CONFIGURATION_REF)
            if not reference then error("publication configuration reference") end
            local data = assert(bounds.object(reference.data))
            local linked = data.resource_ref
            data.resource_ref = nil
            apply(reference)
            local unlinked = raw_call(AGENT, workspace, "bee.gateway.binding:publish_request",
                {binding_id = binding.binding_id, component = "bee/publish-probe",
                    version = "0.0.1-probe.1", visibility = "private", source = "/home/person/work/probe"})
            data.resource_ref = linked
            apply(reference)
            test.is_false(unlinked.ok)
            test.eq((assert(bounds.object(unlinked.error))).code, "DENIED")
        end)
    end)
end
return test.run_cases(define_tests)
