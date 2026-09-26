-- MIT. Agent installation requests end to end through the approval owner:
-- an attempt files one approval for an exact Hub plan, the person decides it,
-- and only an approved request is consumed once and applied by digest. The
-- Hub facade is a recorded fixture; the approvals owner, thread binding and
-- gateway authority are the real ones.
local test = require("test")
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
local CONFIGURATION = "bee:module_installation"
local DIGEST = string.rep("d", 64)
local REMOVAL_DIGEST = string.rep("e", 64)
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
    "bee.harness.catalog:approver_client_policy", "bee.security.approvals:approval_decide_policy"}
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
    return result :: Object
end
local function call(actor_id: string, workspace: string, target: string, request: unknown): Object
    local reply = raw_call(actor_id, workspace, target, request)
    if not reply.ok then
        local fault = reply.error :: Object
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return reply.value :: Object
end
local function apply(entry: Object)
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply " .. tostring(entry.id) .. ": " .. tostring(err)) end
end
local function endpoint(): string
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((entry.data :: Object).address)
end
local function ensure_approver_policy()
    local policies_entry = registry.get("bee:approver_policies")
    if not policies_entry then error("approver policies entry") end
    local list = (policies_entry.data :: Object).policies :: {Object}
    for _, item in ipairs(list) do
        if item.name == APPROVER_POLICY then return end
    end
    list[#list + 1] = {name = APPROVER_POLICY, approvers = {APPROVER}, max_ttl_ms = 60000}
    apply(policies_entry)
end
local function select_policy(name: string): string
    local entry = registry.get(CONFIGURATION)
    if not entry then error("module installation configuration") end
    local data = entry.data :: Object
    local previous = tostring(data.approval_policy)
    data.approval_policy = name
    apply(entry)
    return previous
end
-- One admitted attempt with its gateway binding, as the carrier admits it.
local function attempt(workspace: string): Binding
    local thread = call(AGENT, workspace, "bee.threads.service:create",
        {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Installation"}).thread_id :: string
    local attempt_id = fresh("attempt")
    local action = "action-" .. attempt_id
    call(AGENT, workspace, "bee.threads.service:admit_action", {thread_id = thread, action_id = action,
        idempotency_key = fresh("admit"), admitted = {request_id = fresh("req"), principal_id = AGENT, binding_ref = "test-binding",
            binding_digest = "test-digest", grant_refs = {}, budget_ref = "test-budget", input = {text = "install"}}})
    call(AGENT, workspace, "bee.threads.service:prepare_attempt", {thread_id = thread, action_id = action,
        attempt_id = attempt_id, idempotency_key = fresh("prepare"), prepared = {binding_ref = "test-binding", binding_digest = "test-digest",
            profile_id = "test-profile", profile_digest = "test-profile-digest", placement_binding = "test-placement",
            placement_attempt_id = attempt_id, plan_digest = "test-plan"}})
    local tools = {"install_request", "uninstall_request", "install_status"}
    local admitted = call(AGENT, workspace, "bee.gateway.binding:admit", {subject = AGENT, action_id = action,
        attempt_id = attempt_id, thread_id = thread, owner_incarnation = 1, carrier_epoch = 1, tools = tools,
        ttl_ms = 600000, idempotency_key = fresh("admit"), workspace_id = workspace,
        surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}})
    local binding_id = (admitted.binding :: Object).binding_id :: string
    return {binding_id = binding_id, subject = AGENT, action_id = action, attempt_id = attempt_id,
        thread_id = thread, workspace_id = workspace}
end
-- The Hub facade fixture: one resolvable package and a recorded apply.
type Hub = {calls: {Object}, applies: {Object}, apply_reply: Object}
local function hub(apply_reply: Object?): Hub
    return {calls = {}, applies = {}, apply_reply = apply_reply or {ok = true, replayed = false,
        value = {state = "complete", message = "Dependency root install completed"}}}
end
local function port(binding: Binding, fixture: Hub): installation.Port
    local selected = installation.port(binding)
    selected.hub = function(value: Object, manage: boolean): Object
        fixture.calls[#fixture.calls + 1] = {operation = value.operation, manage = manage}
        local request = (value.request or {}) :: Object
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
        if value.operation == "apply" then
            if not manage then return {ok = false, replayed = false, code = "DENIED", message = "Hub operation is not authorized"} end
            fixture.applies[#fixture.applies + 1] = {request = request, expected_digest = value.expected_digest}
            return fixture.apply_reply
        end
        return {ok = false, replayed = false, code = "INVALID", message = "unexpected Hub operation"}
    end
    return selected
end
local function value_of(reply: Object): Object
    if not reply.ok then
        local fault = reply.error :: Object
        error(tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return reply.value :: Object
end
local function define_tests()
    test.describe("Agent installation requests", function()
        test.it("applies an approved plan once by its digest and refuses the rest", function()
            ensure_approver_policy()
            local previous = select_policy(APPROVER_POLICY)
            local ok, failure = pcall(function()
                local workspace = fresh("install")
                call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
                local binding = attempt(workspace)
                local fixture = hub()
                local selected = port(binding, fixture)
                local filed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool"}))
                test.eq(filed.status, "pending")
                test.eq(filed.version, "1.1.0")
                test.eq(filed.action, "install")
                local request_id = filed.request_id :: string
                local replayed = value_of(installation.request(selected, binding, APPROVER_POLICY, "install",
                    {component = "acme/tool", version = "1.1.0"}))
                test.eq(replayed.request_id, request_id)
                local pending = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(pending.status, "pending")
                test.eq(#fixture.applies, 0)
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(read.requester_id, AGENT)
                test.eq(read.thread_id, binding.thread_id)
                test.eq((read.prompt :: Object).text, "Install acme/tool 1.1.0 from the Hub?")
                local payload = (read.proposal :: Object).payload :: Object
                test.eq(payload.source, "hub")
                test.eq(payload.plan_digest, DIGEST)
                test.eq((payload.dependency_changes :: {string})[1], "install acme/tool 1.1.0")
                test.eq((payload.permission_changes :: {string})[1], "added: acme.tool:files allows fs.get on acme.tool:data")
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = request_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local applied = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(applied.status, "applied")
                test.eq(#fixture.applies, 1)
                local applied_request = fixture.applies[1].request :: Object
                test.eq(fixture.applies[1].expected_digest, DIGEST)
                test.eq(applied_request.action, "install")
                test.eq(applied_request.version, "1.1.0")
                test.eq(applied_request.migration_policy, "up")
                local consumed = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = request_id})
                test.eq(consumed.consumed_effect, "hub-install:" .. request_id)
                local replay: Object = {ok = true, replayed = true, value = {state = "complete"}}
                fixture.apply_reply = replay
                local again = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = request_id}))
                test.eq(again.status, "applied")
                test.eq(#fixture.applies, 2)
                test.eq(fixture.applies[2].expected_digest, DIGEST)

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
            ensure_approver_policy()
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
                local failed = value_of(installation.status(selected, binding, APPROVER_POLICY, {request_id = filed.request_id}))
                test.eq(failed.status, "failed")
                test.eq(failed.code, "STALE")
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
            test.eq((foreign.error :: Object).code, "DENIED")
            local reference = registry.get(installation.CONFIGURATION_REF)
            if not reference then error("installation configuration reference") end
            local data = reference.data :: Object
            local linked = data.resource_ref
            data.resource_ref = nil
            apply(reference)
            local unlinked = raw_call(AGENT, workspace, "bee.gateway.binding:install_request",
                {binding_id = binding.binding_id, component = "acme/tool", version = "1.0.0"})
            data.resource_ref = linked
            apply(reference)
            test.is_false(unlinked.ok)
            test.eq((unlinked.error :: Object).code, "DENIED")
        end)
    end)
end
return test.run_cases(define_tests)
