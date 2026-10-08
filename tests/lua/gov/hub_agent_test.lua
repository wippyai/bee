-- MIT. An agent installs configured Hub applications through consent and governance.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local registry = require("registry")
local http_client = require("http_client")
local launch_policy = require("launch_policy")
local principals = require("principals")
local harness = require("harness")
local application = require("application")
type Object = {[string]: unknown}
local STOCK_POLICY = "bee.driver.claude.security:launch_policy_claude_window"
local GATEWAY_SCOPE = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy",
    "bee.harness.security:carrier_policy", "bee.threads.security:create", "bee.threads.security:observe",
    "bee.threads.security:lifecycle", "bee.threads.security:carrier",
    "bee.tests.support:gateway_manage_policy", "bee.tests.support:gateway_admit_policy", "bee.security.gateway:gateway_materialize_policy"}
type Session = {url: string, token: string}
local function gateway_call(subject: string, workspace: string, target: string, request: Object): Object
    local policies: {security.Policy} = {}
    for index, name in ipairs(GATEWAY_SCOPE) do policies[index] = assert(security.policy(name)) end
    local executor = funcs.new():with_actor(principals.actor(subject, workspace)):with_scope(security.new_scope(policies))
    return harness.value(harness.reply(executor:call(target, request)))
end
-- Opening the listener starts a new epoch that retires earlier bindings, so
-- the sessions share one opening.
local listener_open = false
local function stock_session(workspace: string, name: string): Session
    local decoded = assert(launch_policy.decode(STOCK_POLICY, assert(registry.get(STOCK_POLICY)),
        function(_ref: string): (string?, string?) return "/usr/bin/claude-fixture", nil end))
    local surface = assert(launch_policy.with_workspace(decoded.gateway_surface, workspace))
    local subject = "bee.tests.hub_agent_session_" .. name
    local address = tostring((assert(bounds.object((assert(registry.get("bee.gateway.api:gateway_endpoint"))).data))).address)
    if not listener_open then
        gateway_call(subject, workspace, "bee.gateway.binding:open", {address = address})
        listener_open = true
    end
    local thread = gateway_call(subject, workspace, "bee.threads.binding:create", {thread_id = "hub-agent-" .. name,
        idempotency_key = "hub-agent-thread-" .. name, title = "Stock session " .. name})
    local attempt_id = "hub-agent-attempt-" .. name
    local action_id = "hub-agent-action-" .. name
    gateway_call(subject, workspace, "bee.threads.binding:admit_action", {thread_id = thread.thread_id,
        idempotency_key = "hub-agent-admit-" .. name, action_id = action_id, admitted = {request_id = "hub-agent-request-" .. name,
            principal_id = subject, binding_ref = "bee.driver.claude.binding:binding", binding_digest = "stock", grant_refs = {},
            budget_ref = "stock", input = {text = "work with the counter"}}})
    gateway_call(subject, workspace, "bee.threads.binding:prepare_attempt", {thread_id = thread.thread_id,
        idempotency_key = "hub-agent-prepare-" .. name, action_id = action_id, attempt_id = attempt_id,
        prepared = {binding_ref = "bee.driver.claude.binding:binding", binding_digest = "stock", profile_id = "window",
            profile_digest = "stock", placement_binding = "bee.placement.native.binding:binding",
            placement_attempt_id = "hub-agent-placement-" .. name, plan_digest = "stock"}})
    local admitted = gateway_call(subject, workspace, "bee.gateway.binding:admit", {subject = subject, action_id = action_id,
        attempt_id = attempt_id, thread_id = thread.thread_id, owner_incarnation = 1, carrier_epoch = 1,
        tools = decoded.gateway_tools, hooks = {}, surface = surface, policy_ref = STOCK_POLICY, workspace_id = workspace})
    local binding_id = tostring((assert(bounds.object(admitted.binding))).binding_id)
    local authorized = gateway_call(subject, workspace, "bee.gateway.binding:authorize_materialization",
        {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id})
    local minted = gateway_call(subject, workspace, "bee.gateway.binding:materialize", {attempt_id = attempt_id,
        carrier_epoch = 1, binding_id = binding_id, materialization_key = authorized.materialization_key})
    return {url = "http://" .. address .. "/mcp/" .. action_id, token = tostring(minted.token)}
end
local rpc_id = 0
local function rpc(session: Session, method: string, params: Object): Object
    rpc_id = rpc_id + 1
    local response, err = http_client.post(session.url, {headers = {["Content-Type"] = "application/json",
        Authorization = "Bearer " .. session.token}, body = assert(json.encode({jsonrpc = "2.0", id = rpc_id, method = method, params = params})),
        timeout = 30})
    if err or not response then error("mcp " .. method .. ": " .. tostring(err)) end
    return assert(bounds.object(json.decode(tostring(response.body))))
end
local function listed(session: Session): {[string]: boolean}
    local names: {[string]: boolean} = {}
    local answer = rpc(session, "tools/list", {})
    local result = assert(bounds.object(answer.result), tostring(json.encode(answer)))
    for _, tool in ipairs(principals.objects(result.tools)) do names[tostring(tool.name)] = true end
    return names
end
local function tool_call(session: Session, name: string, arguments: Object): Object
    return rpc(session, "tools/call", {name = name, arguments = arguments})
end
local function structured(answer: Object): Object
    local result = assert(bounds.object(answer.result), tostring(json.encode(answer)))
    test.is_true(result.isError ~= true, tostring(json.encode(result)))
    local content = assert(bounds.object(result.structuredContent))
    return content.ok == true and assert(bounds.object(content.value)) or content
end

local function inbox(workspace: string): {unknown}
    local actor = assert(application.actor(workspace, "hub-agent-inbox", assert(application.definition("bee.approvals.inbox.app:app")), 1))
    return assert(bounds.array(harness.value(harness.reply(funcs.new():with_actor(actor):call(
        "bee.approvals.binding:feed_snapshot", {workspace_id = workspace}))).items, 64))
end
local function define_tests()
    test.describe("Agent Hub application", function()
        test.it("fills a parameter through the Hub trait and installs with one governed approval", function()
            local workspace = harness.isolated("hub-agent")
            local before = harness.running()
            local session = stock_session(workspace, "progress")
            local hidden = listed(session)
            for _, name in ipairs({"components", "install_request", "uninstall_request", "install_status"}) do test.is_nil(hidden[name]) end
            local requested = structured(tool_call(session, "session", {operation = "request_access",
                traits = {"bee.hub:library"}, reason = "Install Progress for this workspace", idempotency_key = "hub-agent-access"}))
            harness.approve(workspace, requested.approval_id)
            test.eq(structured(tool_call(session, "session", {operation = "access_status", approval_id = requested.approval_id})).status, "granted")
            local offered = listed(session)
            for _, name in ipairs({"components", "install_request", "uninstall_request", "install_status"}) do test.is_true(offered[name]) end
            local catalog = structured(tool_call(session, "components", {operation = "catalog", request = {query = "progress"}}))
            test.eq(assert(bounds.object(assert(bounds.array(catalog.items, 64))[1])).component, "bee/progress")
            local request = {component = "bee/progress", version = "1.0.0", parameters = {{name = "app.progress:title", value = "Agent progress"}}}
            local filed = structured(tool_call(session, "install_request", request))
            test.eq(filed.status, "pending")
            test.eq(structured(tool_call(session, "install_request", request)).request_id, filed.request_id)
            test.eq(structured(tool_call(session, "install_status", {request_id = filed.request_id})).status, "pending")
            local approvals = 0
            for _, raw in ipairs(inbox(workspace)) do
                local item = assert(bounds.object(assert(bounds.object(raw)).value))
                if item.state == "pending" then
                    approvals = approvals + 1
                    test.eq(item.approval_id, filed.approval_id)
                    local proposal = assert(bounds.object(item.proposal))
                    test.is_true(proposal.ref ~= "bee.hub:apply")
                    test.eq(#assert(bounds.array(assert(bounds.object(proposal.payload)).migrations, 8)), 2)
                end
            end
            test.eq(approvals, 1)
            harness.approve(workspace, filed.approval_id)
            harness.drain()
            local installed = structured(tool_call(session, "install_status", {request_id = filed.request_id}))
            test.eq(installed.status, "applied", tostring(json.encode(installed)))
            test.eq(assert(bounds.object(assert(bounds.object((assert(registry.get("app.progress:app"))).meta)).application)).title, "Agent progress")
            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = "hub:bee/progress", receipt_key = "hub-agent-cleanup"}))
            harness.close_presented(before)
        end)
    end)
end
return test.run_cases(define_tests)
