-- MIT. Capability elevation end to end: an agent attempt asks for one
-- host catalog capability, the person approves its catalog wording bound
-- to that thread and attempt, consumption writes one resources grant row
-- for the authenticated thread actor, and placement resolves it for that
-- attempt only. A child attempt resolves nothing.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local AGENT = "bee.test.elevation_agent"
local MANAGER = "bee.test.elevation_manager"
local APPROVER = "bee.test.elevation_approver"
local PLACEMENT = "bee.test.elevation_placement"
local APPROVER_POLICY = "elevation-fixture"
local ROOT = "bee.harness.catalog:project_fixture"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:elevation_client_policy", "bee.security.gateway:gateway_manage_policy",
    "bee.security.gateway:gateway_admit_policy", "bee.security.threads:thread_create_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_observe_policy",
    "bee.harness.catalog:approver_client_policy",
    "bee.security.resources:resource_manage_policy", "bee.security.resources:resource_grant_policy",
    "bee.security.resources:resource_resolve_policy", "bee.security.approvals:approval_decide_policy"}
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
local function code(actor_id: string, workspace: string, target: string, request: unknown): string
    local reply = raw_call(actor_id, workspace, target, request)
    if reply.ok then return "OK" end
    return tostring((reply.error :: Object).code)
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
local function admit_root()
    local entry = registry.get("bee:resource_roots")
    if not entry then error("resource roots entry") end
    local data = entry.data :: Object
    local roots = data.roots :: {{[string]: unknown}}
    for _, root in ipairs(roots) do
        if tostring(root.root_ref) == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    apply(entry)
end
-- A test-only elevation template with a $parameter resource source, so
-- consumption maps the approved capability to one workspace association.
-- The row is removed again before the test ends.
local function template_count(): integer
    local entry = registry.get("bee:capability_catalog")
    if not entry then error("capability catalog entry") end
    return #(((entry.data :: Object).capabilities) :: {unknown})
end
local function add_template()
    local entry = registry.get("bee:capability_catalog")
    if not entry then error("capability catalog entry") end
    local rows = (entry.data :: Object).capabilities :: {Object}
    rows[#rows + 1] = {id = "test.elevation", revision = 1, confirm = "standard",
        parameters = {name = "name"}, text = "Use test elevation database {name}",
        policies = {{operation = "database.use", resource = "$name", scope = {name = "$name"}}},
        resources = {{kind = "db.sql.sqlite", mode = "dedicated", source = "$name"}}}
    apply(entry)
end
local function remove_template(previous: integer)
    local entry = registry.get("bee:capability_catalog")
    if not entry then error("capability catalog entry") end
    local rows = (entry.data :: Object).capabilities :: {Object}
    while #rows > previous do rows[#rows] = nil end
    apply(entry)
end
local function define_tests()
    test.describe("Capability elevation", function()
        test.it("elevates one attempt through a thread-bound approval into a placement grant", function()
            ensure_approver_policy()
            admit_root()
            local workspace = fresh("elevation")
            local thread = call(AGENT, workspace, "bee.threads.service:create",
                {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Elevation"}).thread_id :: string
            call(AGENT, workspace, "bee.gateway.binding:open", {address = endpoint()})
            local attempt = fresh("attempt")
            local action = "action-" .. attempt
            call(AGENT, workspace, "bee.threads.service:admit_action", {thread_id = thread, action_id = action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("req"), principal_id = AGENT, binding_ref = "test-binding",
                    binding_digest = "test-digest", grant_refs = {}, budget_ref = "test-budget", input = {text = "elevate"}}})
            call(AGENT, workspace, "bee.threads.service:prepare_attempt", {thread_id = thread, action_id = action,
                attempt_id = attempt, idempotency_key = fresh("prepare"), prepared = {binding_ref = "test-binding", binding_digest = "test-digest",
                    profile_id = "test-profile", profile_digest = "test-profile-digest", placement_binding = "test-placement",
                    placement_attempt_id = attempt, plan_digest = "test-plan"}})
            local tools = {"request_capability", "capability_status"}
            local surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {},
                fixed_context = {}, dynamic_keys = {}, access = {policy = APPROVER_POLICY, traits = {}}}
            local binding = call(AGENT, workspace, "bee.gateway.binding:admit", {subject = AGENT, action_id = action,
                attempt_id = attempt, thread_id = thread, owner_incarnation = 1, carrier_epoch = 1,
                tools = tools, ttl_ms = 600000, idempotency_key = fresh("admit"), surface = surface, workspace_id = workspace})
            local binding_id = (binding.binding :: Object).binding_id :: string
            call(MANAGER, workspace, "bee.resources.binding:associate", {workspace_id = workspace,
                name = "elevdb", root_ref = ROOT, subpath = "", allowed_access = "write"})
            local previous = template_count()
            add_template()
            local outcome = (function(): Object
                local requested = call(AGENT, workspace, "bee.gateway.binding:request_capability", {binding_id = binding_id,
                    capability = "test.elevation", parameters = {name = "elevdb"}, ttl_ms = 60000})
                local approval_id = requested.approval_id :: string
                test.is_nil(requested.grant_id)
                local pending = call(AGENT, workspace, "bee.gateway.binding:capability_status",
                    {binding_id = binding_id, approval_id = approval_id})
                test.eq(pending.status, "pending")
                local read = call(APPROVER, workspace, "bee.approvals.binding:read", {approval_id = approval_id})
                test.eq(read.requester_id, AGENT)
                test.eq(read.thread_id, thread)
                local proposal = (read.proposal :: Object).payload :: Object
                test.eq(proposal.capability, "test.elevation")
                test.eq(proposal.attempt_id, attempt)
                test.is_true(tostring(proposal.wording):find("Use test elevation database elevdb", 1, true) ~= nil)
                call(APPROVER, workspace, "bee.approvals.binding:decide", {approval_id = approval_id,
                    expected_revision = read.revision, decision = "approved", proposal_digest = read.proposal_digest})
                local granted = call(AGENT, workspace, "bee.gateway.binding:capability_status",
                    {binding_id = binding_id, approval_id = approval_id})
                test.eq(granted.status, "granted")
                local grant_id = granted.grant_id :: string
                local replayed = call(AGENT, workspace, "bee.gateway.binding:capability_status",
                    {binding_id = binding_id, approval_id = approval_id})
                test.eq(replayed.grant_id, grant_id)
                local resolved = call(PLACEMENT, workspace, "bee.resources.binding:resolve",
                    {grant_id = grant_id, subject = AGENT, audience = AGENT, attempt_id = attempt})
                test.eq(resolved.name, "elevdb")
                test.eq(resolved.access, "write")
                test.eq(code(PLACEMENT, workspace, "bee.resources.binding:resolve",
                    {grant_id = grant_id, subject = AGENT, audience = AGENT, attempt_id = "attempt-child"}), "DENIED")
                call(AGENT, workspace, "bee.resources.binding:revoke", {grant_id = grant_id})
                test.eq(code(PLACEMENT, workspace, "bee.resources.binding:resolve",
                    {grant_id = grant_id, subject = AGENT, audience = AGENT, attempt_id = attempt}), "REVOKED")
                return granted
            end)()
            remove_template(previous)
            test.eq(outcome.status, "granted")
            test.eq(template_count(), previous)
        end)
    end)
end
return test.run_cases(define_tests)
