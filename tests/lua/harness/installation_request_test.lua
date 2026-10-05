-- MIT. Agent installation requests end to end through the approval owner:
-- an attempt files one approval for an exact Hub plan, the person decides it,
-- and only an approved request is consumed once and applied by digest. The
-- Hub facade is a recorded fixture; the approvals owner, thread binding and
-- gateway authority are the real ones.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local installation = require("installation")
local AGENT = "bee.test.install_agent"
local OTHER = "bee.test.install_other"
local APPROVER = "bee.test.install_approver"
local APPROVER_POLICY = "installation-fixture"
local OTHER_APPROVER_POLICY = "installation-fixture-other"
local CONFIGURATION = "bee.gateway.env:module_installation"
local DIGEST = string.rep("d", 64)
local REMOVAL_DIGEST = string.rep("e", 64)
local base_port = installation.port
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:installation_client_policy", "bee.tests.support:gateway_manage_policy",
    "bee.tests.support:gateway_admit_policy", "bee.threads.security:create",
    "bee.threads.security:lifecycle", "bee.threads.security:observe",
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
    if not entry then error("module installation configuration") end
    local data = assert(bounds.object(entry.data))
    local previous = tostring(data.approval_policy)
    data.approval_policy = name
    apply(entry)
    return previous
end
-- One admitted attempt with its gateway binding, as the carrier admits it.
local function attempt(workspace: string): Binding
    local thread = call(AGENT, workspace, "bee.threads.binding:create",
        {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Installation"}).thread_id
    local attempt_id = fresh("attempt")
    local action = "action-" .. attempt_id
    call(AGENT, workspace, "bee.threads.binding:admit_action", {thread_id = thread, action_id = action,
        idempotency_key = fresh("admit"), admitted = {request_id = fresh("req"), principal_id = AGENT, binding_ref = "test-binding",
            binding_digest = "test-digest", grant_refs = {}, budget_ref = "test-budget", input = {text = "install"}}})
    call(AGENT, workspace, "bee.threads.binding:prepare_attempt", {thread_id = thread, action_id = action,
        attempt_id = attempt_id, idempotency_key = fresh("prepare"), prepared = {binding_ref = "test-binding", binding_digest = "test-digest",
            profile_id = "test-profile", profile_digest = "test-profile-digest", placement_binding = "test-placement",
            placement_attempt_id = attempt_id, plan_digest = "test-plan"}})
    local tools = {"install_request", "uninstall_request", "install_status"}
    local admitted = call(AGENT, workspace, "bee.gateway.binding:admit", {subject = AGENT, action_id = action,
        attempt_id = attempt_id, thread_id = thread, owner_incarnation = 1, carrier_epoch = 1, tools = tools,
        ttl_ms = 600000, idempotency_key = fresh("admit"), workspace_id = workspace,
        surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}})
    local binding_id = (assert(bounds.object(admitted.binding))).binding_id
    assert(type(binding_id) == "string" and type(thread) == "string")
    return {binding_id = binding_id, subject = AGENT, action_id = action, attempt_id = attempt_id,
        thread_id = thread, workspace_id = workspace}
end
-- The Hub facade fixture: one resolvable package and a recorded apply.
type Hub = {calls: {Object}, applies: {Object}, apply_reply: Object, receipts: {[string]: Object}, uncertain_after_apply: boolean}
local function hub(apply_reply: Object?, uncertain_after_apply: boolean?): Hub
    return {calls = {}, applies = {}, apply_reply = apply_reply or {ok = true, replayed = false,
        value = {state = "complete", message = "Dependency root install completed"}}, receipts = {},
        uncertain_after_apply = uncertain_after_apply == true}
end
local function port(binding: Binding, fixture: Hub): installation.Port
    local selected = base_port(binding)
    selected.hub = function(value: Object, manage: boolean): Object
        fixture.calls[#fixture.calls + 1] = {operation = value.operation, manage = manage}
        local request = assert(bounds.object((value.request or {})))
        if value.operation == "installed" then return {ok = true, replayed = false, value = {version = 1, modules = {}, roots = {}}} end
        if value.operation == "details" then
            return {ok = true, replayed = false, value = {component = request.component, versions = {
                {version = "1.0.0", yanked = false}, {version = "1.1.0", yanked = false}, {version = "2.0.0", yanked = true}}}}
        end
        if value.operation == "plan" then
            local version = request.action == "uninstall" and "" or request.version
            local digest = request.action == "uninstall" and REMOVAL_DIGEST or DIGEST
            return {ok = true, replayed = false, value = {digest = digest, ready = true, base_revision = 3,
                request = {action = request.action, component = request.component, version = version,
                    migration_policy = request.migration_policy, parameters = {}},
                modules = {{component = request.component, version = version, previous_version = "",
                    change = request.action == "uninstall" and "remove" or "install"}},
                policy_changes = {{id = "acme.tool:files", component = request.component, change = "add",
                    actions = {"fs.get"}, resources = {"acme.tool:data"}, expression = false}},
                migrations = {}, starts = {}, capabilities = {"acme.tool:files"}, missing = {}}}
        end
        if value.operation == "status" then
            local expected = tostring(value.expected_digest or "")
            local receipt = fixture.receipts[expected]
            if receipt then return {ok = true, replayed = false, value = receipt} end
            return {ok = false, replayed = false, code = "NOT_FOUND", message = "no published operation for this plan"}
        end
        if value.operation == "apply" then
            if not manage then return {ok = false, replayed = false, code = "DENIED", message = "Hub operation is not authorized"} end
            local expected = tostring(value.expected_digest or "")
            local recorded = fixture.receipts[expected]
            if recorded then
                fixture.applies[#fixture.applies + 1] = {request = request, expected_digest = expected, replayed = true}
                return {ok = true, replayed = true, value = recorded}
            end
            fixture.applies[#fixture.applies + 1] = {request = request, expected_digest = expected, replayed = false}
            if fixture.uncertain_after_apply then
                fixture.uncertain_after_apply = false
                local receipt = fixture.apply_reply.value
                if type(receipt) == "table" then fixture.receipts[expected] = assert(bounds.object(receipt)) end
                return {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub reply was lost after publication"}
            end
            if fixture.apply_reply.ok == true then
                local receipt = fixture.apply_reply.value
                if type(receipt) == "table" then fixture.receipts[expected] = assert(bounds.object(receipt)) end
            end
            return fixture.apply_reply
        end
        return {ok = false, replayed = false, code = "INVALID", message = "unexpected Hub operation"}
    end
    return selected
end
local function drain(fixture: Hub): (integer, string?)
    local original_port = installation.port
    local drained: integer = 0
    local drain_error: string? = nil
    installation.port = function(worker_binding: Binding): installation.Port
        return port(worker_binding, fixture)
    end
    local ok, failure = pcall(function()
        drained, drain_error = installation.drain_approved()
    end)
    installation.port = original_port
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
    test.describe("Agent installation requests", function()
        test.it("retries a consumed approved plan by its digest and refuses the rest", function()
            ensure_approver_policy(APPROVER_POLICY)
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("install")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub(nil, true)
                local selected = port(binding, fixture)
                local filed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool"}))
                test.eq(filed.status, "pending")
                test.eq(filed.version, "1.1.0")
                test.eq(filed.action, "install")
                local request_id = filed.request_id
                local replayed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool", version = "1.1.0"}))
                test.eq(replayed.request_id, request_id)
                local pending = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(pending.status, "pending")
                test.eq(#fixture.applies, 0)
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(read.requester_id, AGENT)
                test.eq(read.thread_id, binding.thread_id)
                test.eq((assert(bounds.object(read.prompt))).text, "Install acme/tool 1.1.0 from the Hub?")
                local payload = assert(bounds.object((assert(bounds.object(read.proposal))).payload))
                test.eq(payload.source, "hub")
                test.eq(payload.binding_id, binding.binding_id)
                test.eq(payload.plan_digest, DIGEST)
                test.eq((principals.strings(payload.dependency_changes))[1], "install acme/tool 1.1.0")
                test.eq((principals.strings(payload.permission_changes))[1], "added: acme.tool:files allows fs.get on acme.tool:data")
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local drained, drain_error = drain(fixture)
                test.is_nil(drain_error)
                test.eq(drained, 1)
                test.eq(#fixture.applies, 1)
                test.eq(fixture.applies[1].expected_digest, DIGEST)
                test.eq(fixture.applies[1].replayed, false)
                local consumed = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(consumed.consumer_id, AGENT)
                test.eq(consumed.consumed_effect, "hub-install:" .. request_id)
                test.is_nil(consumed.effect_completed_at)
                local observed = value_of(installation.status(selected, binding, APPROVER_POLICY,
                    {request_id = request_id}))
                test.eq(observed.status, "applied")
                test.eq(#fixture.applies, 1)
                local recovered, recovery_error = drain(fixture)
                test.is_nil(recovery_error)
                test.eq(recovered, 1)
                test.eq(#fixture.applies, 2)
                local applied_request = assert(bounds.object(fixture.applies[2].request))
                test.eq(fixture.applies[2].expected_digest, DIGEST)
                test.eq(fixture.applies[2].replayed, true)
                test.eq(applied_request.action, "install")
                test.eq(applied_request.version, "1.1.0")
                test.eq(applied_request.migration_policy, "up")
                local applied = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(applied.status, "applied")
                test.eq(applied.replayed, true)
                test.eq(#fixture.applies, 2)
                local completed = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(completed.consumer_id, AGENT)
                test.eq(completed.consumed_effect, "hub-install:" .. request_id)
                test.not_nil(completed.effect_completed_at)
                test.eq((assert(bounds.object(completed.effect_result))).replayed, true)
                local again = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(again.status, "applied")
                test.eq(again.replayed, true)
                test.eq(#fixture.applies, 2)
                local drained_again, drain_again_error = installation.drain_approved()
                test.is_nil(drain_again_error)
                test.eq(drained_again, 0)

                local other = attempt(workspace)
                local foreign = installation.status(port(other, hub()), other, APPROVER_POLICY, {request_id = request_id})
                test.is_false(foreign.ok)
                test.eq(foreign.error and foreign.error.code, "DENIED")

                local removal_fixture = hub()
                local removal = port(binding, removal_fixture)
                local removal_filed = value_of(installation.request(removal, binding, APPROVER_POLICY, "uninstall",
                    {component = "acme/tool"}))
                test.eq(removal_filed.action, "uninstall")
                local removal_read = call(APPROVER, workspace, "bee.approvals.binding:read",
                    {approval_id = removal_filed.request_id})
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = removal_filed.request_id,
                    expected_revision = removal_read.revision, decision = "denied", proposal_digest = removal_read.proposal_digest})
                local refused = value_of(installation.status(removal, binding, APPROVER_POLICY,
                    {request_id = removal_filed.request_id}))
                test.eq(refused.status, "refused")
                test.eq(refused.code, "DENIED")
                test.eq(#removal_fixture.applies, 0)
            end)
            select_policy(previous)
            if not ok then error(failure) end
        end)

        test.it("reports a failed apply with the Hub code", function()
            ensure_approver_policy(APPROVER_POLICY)
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("install-stale")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub({ok = false, replayed = false, code = "STALE",
                    message = "the install plan changed; refresh and confirm it again"})
                local selected = port(binding, fixture)
                local filed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool", version = "1.0.0"}))
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = filed.request_id})
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = filed.request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local drained, drain_error = drain(fixture)
                test.is_nil(drain_error)
                test.eq(drained, 1)
                local failed = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = filed.request_id}))
                test.eq(failed.status, "failed")
                test.eq(failed.code, "STALE")
                local completed = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = filed.request_id})
                test.not_nil(completed.effect_completed_at)
                local drained_again, drain_again_error = installation.drain_approved()
                test.is_nil(drain_again_error)
                test.eq(drained_again, 0)
            end)
            select_policy(previous)
            if not ok then error(failure) end
        end)

        test.it("does not apply an installation consumed by another effect owner", function()
            ensure_approver_policy(APPROVER_POLICY)
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("install-consumer")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub()
                local selected = port(binding, fixture)
                local filed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool", version = "1.0.0"}))
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = filed.request_id})
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = filed.request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local consumed = call(OTHER, workspace, "bee.approvals.binding:consume", {approval_id = filed.request_id,
                    proposal_digest = read.proposal_digest, owner_incarnation = read.owner_incarnation,
                    effect_key = "hub-install:" .. tostring(filed.request_id)})
                test.eq(consumed.consumer_id, OTHER)
                local refused = installation.status(selected, binding, APPROVER_POLICY, {request_id = filed.request_id})
                test.is_false(refused.ok)
                test.eq((assert(bounds.object(refused.error))).code, "DENIED")
                local drained, drain_error = drain(fixture)
                test.is_nil(drain_error)
                test.eq(drained, 0)
                test.eq(#fixture.applies, 0)
            end)
            select_policy(previous)
            if not ok then error(failure) end
        end)

        test.it("uses the host-selected installation policy in the owner worker", function()
            ensure_approver_policy(APPROVER_POLICY)
            ensure_approver_policy(OTHER_APPROVER_POLICY)
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("install-policy")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub()
                local selected = port(binding, fixture)
                local filed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool", version = "1.0.0"}))
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = filed.request_id})
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = filed.request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                select_policy(OTHER_APPROVER_POLICY)
                local refused, refuse_error = drain(fixture)
                select_policy(APPROVER_POLICY)
                test.is_nil(refuse_error)
                test.eq(refused, 0)
                test.eq(#fixture.applies, 0)
                local applied, apply_error = drain(fixture)
                test.is_nil(apply_error)
                test.eq(applied, 1)
                test.eq(#fixture.applies, 1)
            end)
            select_policy(previous)
            if not ok then error(failure) end
        end)

        test.it("refuses a caller that is not the bound subject and a host without an installation link", function()
            local workspace = fresh("install-denied")
            call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
            local binding = attempt(workspace)
            local foreign = raw_call(OTHER, workspace, "bee.gateway.binding:install_request",
                {binding_id = binding.binding_id, component = "acme/tool", version = "1.0.0"})
            test.is_false(foreign.ok)
            test.eq((assert(bounds.object(foreign.error))).code, "DENIED")
            local reference = registry.get(installation.CONFIGURATION_REF)
            if not reference then error("installation configuration reference") end
            local data = assert(bounds.object(reference.data))
            local linked = data.resource_ref
            data.resource_ref = nil
            apply(reference)
            local unlinked = raw_call(AGENT, workspace, "bee.gateway.binding:install_request",
                {binding_id = binding.binding_id, component = "acme/tool", version = "1.0.0"})
            data.resource_ref = linked
            apply(reference)
            test.is_false(unlinked.ok)
            test.eq((assert(bounds.object(unlinked.error))).code, "DENIED")
        end)
    end)
end
return test.run_cases(define_tests)
