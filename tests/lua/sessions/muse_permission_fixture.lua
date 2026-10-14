-- SPDX-License-Identifier: MIT
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local env = require("env")
local exec = require("exec")
local json = require("json")
local time = require("time")
local bounds = require("bounds")
local admission = require("admission")
local catalog = require("catalog")
local harness = require("harness")
local adapter = require("adapter")
local configuration = require("configuration")
type Object = {[string]: unknown}
local M = {}
local ACCEPTANCE = "bee.tests.sessions:muse_hook_acceptance"
local WORKSPACE = string.rep("a", 32)
local function policies(names: {string}): security.Scope
    local values: {security.Policy} = {}
    for _, name in ipairs(names) do values[#values + 1] = assert(security.policy(name)) end
    return security.new_scope(values)
end
local function value(caller: funcs.Executor, target: string, input: Object): Object
    local raw, err = caller:call(target, input)
    if err then error(tostring(err)) end
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then error(tostring(assert(bounds.object(reply.error)).message)) end
    return assert(bounds.object(reply.value))
end
function M.with_host(provider: string, body: (admission.Plan?) -> ())
    local POLICY = "bee.driver." .. provider .. ".security:launch_policy_" .. provider .. "_window"
    local DEFINITION = "bee.driver." .. provider .. ".profiles:default_window"
    local BINDING = "bee.driver." .. provider .. ".binding:binding"
    local original = assert(registry.get(POLICY))
    local changed = assert(registry.get(POLICY))
    local data = assert(bounds.object(changed.data))
    local executable = assert(bounds.text(env.get("bee.harness.catalog:fixture_bin"))) .. "/claude"
    data.fixture = true
    data.executable_env = {}
    data.executables = {[provider] = executable}
    local caller = funcs.new():with_actor(assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))):with_scope(
        policies({"bee.harness.security:carrier_policy", "bee.security.gateway:gateway_materialize_policy"}))
    local measured = value(caller, "bee.placement.native.binding:measure_executable", {path = executable})
    local candidates = assert(catalog.usable(assert(catalog.snapshot())))
    local binding_digest, profile_digest = "", ""
    for _, candidate in ipairs(candidates) do
        if candidate.binding_id == BINDING then
            binding_digest, profile_digest = candidate.binding_digest.entry, candidate.profile_digest.entry
        end
    end
    assert(binding_digest ~= "")
    local declaration = assert(registry.get("bee.driver.permission:permission_request_hook"))
    local decoded = assert(adapter.decode(declaration.id, assert(bounds.object(declaration.data)).adapter))
    local acceptance: Object = {id = ACCEPTANCE, kind = "registry.entry", meta = {type = "harness.permission_acceptance"},
        data = {acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING,
            profile_id = "window", binding_digest = binding_digest, profile_digest = profile_digest,
            adapter_ref = declaration.id, adapter_digest = decoded.digest, fixture_digest = string.rep("a", 64),
            executable_revision = measured.revision, executable_kind = measured.kind, executable_digest = measured.digest,
            proof_revision = "bee.permission-proof@1", accepted_by = "fixture-operator", accepted_at = "2026-10-08T00:00:00.000Z"}}}
    data.permission_exchange = {adapter_ref = declaration.id, acceptance_ref = ACCEPTANCE, fixture_digest = string.rep("a", 64),
        approver_policy = "workspace-application-delivery", poll_ms = 50, ttl_ms = 60000}
    local changes = assert(registry.snapshot()):changes()
    assert(changes:create(acceptance)); assert(changes:update(changed)); assert(changes:apply())
    local ok, failure = pcall(function()
        local plan, refused = admission.resolve(DEFINITION, "window", WORKSPACE)
        assert(plan, tostring(refused and refused.error and refused.error.message))
        body(plan)
    end)
    local restore = assert(registry.snapshot()):changes()
    assert(restore:update(original)); assert(restore:delete(ACCEPTANCE)); assert(restore:apply())
    assert(ok, tostring(failure))
end
function M.capture(provider: string, event: string): Object
    assert(event == "PermissionRequest" or event == "Stop")
    local root = assert(bounds.text(env.get("bee.harness.catalog:fixture_streams")))
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local proc = assert(executor:exec("cat " .. root .. "/" .. provider .. "/hooks-1/" .. event .. ".json"))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local content = ""
    while true do
        local chunk: unknown = stdout:read(8192)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. chunk
    end
    proc:wait(); stdout:close(); executor:release()
    return assert(bounds.object(json.decode(content)))
end
function M.binding(provider: string, session: string, thread: string, attempt: string, action: string): string
    local caller = funcs.new():with_actor(assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))):with_scope(
        policies({"bee.harness.security:carrier_policy", "bee.tests.support:gateway_manage_policy"}))
    value(caller, "bee.gateway.binding:open", {address = assert(configuration.endpoint())})
    local admitted = value(caller, "bee.gateway.binding:admit", {subject = session, thread_id = thread, attempt_id = attempt,
        action_id = action, owner_incarnation = 1, carrier_epoch = 1, hooks = {"PermissionRequest"}, tools = {},
        policy_ref = "bee.driver." .. provider .. ".security:launch_policy_" .. provider .. "_window", workspace_id = WORKSPACE})
    return assert(bounds.id(assert(bounds.object(admitted.binding)).binding_id))
end
function M.decide(session: string): string
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":fixture-inbox",
        {workspace_id = WORKSPACE, definition_id = "bee.approvals.inbox.app:app"}))
    local caller = funcs.new():with_actor(actor):with_scope(policies({"bee.approvals:client_test_policy", "bee.security.approvals:approval_decide_policy"}))
    local deadline = time.now():unix_nano() + 10000000000
    while time.now():unix_nano() < deadline do
        local inbox = value(caller, "bee.approvals.binding:inbox", {workspace_id = WORKSPACE, limit = 64})
        for _, row in ipairs(assert(bounds.array(inbox.changes, 64))) do
            local item = assert(bounds.object(row))
            local approval = bounds.object(item.request)
            if approval and approval.requesting_session == session and approval.state == "pending" then
                value(caller, "bee.approvals.binding:decide", {approval_id = approval.approval_id, expected_revision = approval.revision,
                    proposal_digest = approval.proposal_digest, decision = "approved"})
                return assert(bounds.id(approval.approval_id))
            end
        end
        time.sleep("50ms")
    end
    error("Driver permission did not reach Needs you")
end
return M
