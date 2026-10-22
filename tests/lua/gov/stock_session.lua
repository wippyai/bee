-- MIT. A stock Claude Code session in a workspace, for suites that drive the
-- gateway as an agent: the shipped window launch policy as a launch without a
-- saved profile decodes it, its gateway binding admitted with that policy's
-- own surface, and an MCP client over the gateway listener with the binding's
-- token.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local json = require("json")
local http_client = require("http_client")
local bounds = require("bounds")
local harness = require("harness")
local launch_policy = require("launch_policy")
local principals = require("principals")

local M = {}
type Object = {[string]: unknown}
type Session = {url: string, token: string, thread_id: string}

local STOCK_POLICY = "bee.driver.claude.security:launch_policy_claude_window"
local GATEWAY_SCOPE = {"bee.tests.harness:carrier_client_policy", "bee.tests.harness:gateway_client_policy",
    "bee.harness.security:carrier_policy", "bee.threads.security:create", "bee.threads.security:observe",
    "bee.threads.security:lifecycle", "bee.threads.security:carrier",
    "bee.tests.support:gateway_manage_policy", "bee.tests.support:gateway_admit_policy", "bee.security.gateway:gateway_materialize_policy"}

local function gateway_call(subject: string, workspace: string, target: string, request: Object): Object
    local policies: {security.Policy} = {}
    for index, name in ipairs(GATEWAY_SCOPE) do policies[index] = assert(security.policy(name)) end
    local executor = funcs.new():with_actor(principals.actor(subject, workspace)):with_scope(security.new_scope(policies))
    return harness.value(harness.reply(executor:call(target, request)))
end

-- Opening the listener starts a new epoch that retires earlier bindings, so
-- the sessions of one suite share one opening.
local listener_open = false

-- open starts the session label names in workspace; label keeps subjects,
-- threads and actions of different suites apart.
function M.open(workspace: string, label: string): Session
    local decoded = assert(launch_policy.decode(STOCK_POLICY, assert(registry.get(STOCK_POLICY)),
        function(_ref: string): (string?, string?) return "/usr/bin/claude-fixture", nil end))
    local surface = assert(launch_policy.with_workspace(decoded.gateway_surface, workspace))
    local subject = "bee.tests.session_" .. (label:gsub("-", "_"))
    local address = tostring((assert(bounds.object((assert(registry.get("bee.gateway.api:gateway_endpoint"))).data))).address)
    if not listener_open then
        gateway_call(subject, workspace, "bee.gateway.binding:open", {address = address})
        listener_open = true
    end
    local thread = gateway_call(subject, workspace, "bee.threads.binding:create", {thread_id = label,
        idempotency_key = label .. "-thread", title = "Stock session " .. label})
    local attempt_id = label .. "-attempt"
    local action_id = label .. "-action"
    gateway_call(subject, workspace, "bee.threads.binding:admit_action", {thread_id = thread.thread_id,
        idempotency_key = label .. "-admit", action_id = action_id, admitted = {request_id = label .. "-request",
            principal_id = subject, binding_ref = "bee.drivers.claude.binding:binding", binding_digest = "stock", grant_refs = {},
            budget_ref = "stock", input = {text = "work in the workspace"}}})
    gateway_call(subject, workspace, "bee.threads.binding:prepare_attempt", {thread_id = thread.thread_id,
        idempotency_key = label .. "-prepare", action_id = action_id, attempt_id = attempt_id,
        prepared = {binding_ref = "bee.drivers.claude.binding:binding", binding_digest = "stock", profile_id = "window",
            profile_digest = "stock", placement_binding = "bee.placement.native.binding:binding",
            placement_attempt_id = label .. "-placement", plan_digest = "stock"}})
    local admitted = gateway_call(subject, workspace, "bee.gateway.binding:admit", {subject = subject, action_id = action_id,
        attempt_id = attempt_id, thread_id = thread.thread_id, owner_incarnation = 1, carrier_epoch = 1,
        tools = decoded.gateway_tools, hooks = {}, surface = surface, policy_ref = STOCK_POLICY, workspace_id = workspace})
    local binding_id = tostring((assert(bounds.object(admitted.binding))).binding_id)
    local authorized = gateway_call(subject, workspace, "bee.gateway.binding:authorize_materialization",
        {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id})
    local minted = gateway_call(subject, workspace, "bee.gateway.binding:materialize", {attempt_id = attempt_id,
        carrier_epoch = 1, binding_id = binding_id, materialization_key = authorized.materialization_key})
    return {url = "http://" .. address .. "/mcp/" .. action_id, token = tostring(minted.token), thread_id = tostring(thread.thread_id)}
end

local rpc_id = 0
function M.rpc(session: Session, method: string, params: Object): Object
    rpc_id = rpc_id + 1
    local response, err = http_client.post(session.url, {headers = {["Content-Type"] = "application/json",
        Authorization = "Bearer " .. session.token}, body = assert(json.encode({jsonrpc = "2.0", id = rpc_id, method = method, params = params})),
        timeout = 30})
    if err or not response then error("mcp " .. method .. ": " .. tostring(err)) end
    return assert(bounds.object(json.decode(tostring(response.body))))
end

-- listed names the tools the session lists.
function M.listed(session: Session): {[string]: boolean}
    local names: {[string]: boolean} = {}
    local answer = M.rpc(session, "tools/list", {})
    local result = assert(bounds.object(answer.result), tostring(json.encode(answer)))
    for _, tool in ipairs(principals.objects(result.tools)) do names[tostring(tool.name)] = true end
    return names
end

function M.tool_call(session: Session, name: string, arguments: Object): Object
    return M.rpc(session, "tools/call", {name = name, arguments = arguments})
end

-- structured is a successful tool result's value; a tool error raises.
function M.structured(answer: Object): Object
    local result = assert(bounds.object(answer.result), tostring(json.encode(answer)))
    if result.isError == true then error("tool refused: " .. tostring(json.encode(result))) end
    local content = assert(bounds.object(result.structuredContent))
    return content.ok == true and assert(bounds.object(content.value)) or content
end

return M
