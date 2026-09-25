-- SPDX-License-Identifier: MIT
-- Real approval owner and HTTP client prove a grant is local to one binding.
local funcs = require("funcs")
local http_client = require("http_client")
local json = require("json")
local registry = require("registry")
local bounds = require("bounds")
type Object = {[string]: unknown}
local ACTOR = "bee.test.gateway"
local THREAD = "access-thread"
-- The binding names the approval workspace; the surface declaration carries none.
local WORKSPACE = "access-workspace"
local function object(raw: unknown): Object
    local value = bounds.object(raw)
    if not value then error("expected object") end
    return value
end
local function value(reply: Object): Object
    if reply.ok ~= true then error("operation refused: " .. tostring(json.encode(reply.error))) end
    return object(reply.value)
end
local function call(target: string, request: Object): Object
    local raw, err = funcs.call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return object(raw)
end
local function rpc(address: string, action: string, token: string, name: string, arguments: Object): Object
    local encoded, encode_error = json.encode({jsonrpc = "2.0", id = 1, method = "tools/call", params = {name = name, arguments = arguments}})
    if not encoded then error(tostring(encode_error)) end
    local response, err = http_client.post("http://" .. address .. "/mcp/" .. action,
        {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = encoded, timeout = "8s"})
    if not response then error(tostring(err)) end
    if response.status_code ~= 200 then error("unexpected HTTP status") end
    local raw, decode_error = json.decode(tostring(response.body))
    if decode_error then error(tostring(decode_error)) end
    local reply = object(raw)
    if reply.error ~= nil then return {ok = false, error = reply.error} end
    local result = object(reply.result)
    local content = result.content
    if type(content) ~= "table" then error("missing MCP content") end
    local text = bounds.text(object(content[1]).text)
    if not text then error("missing MCP text") end
    local decoded, content_error = json.decode(text)
    if content_error then error(tostring(content_error)) end
    return object(decoded)
end
local function run(address: string)
    local entry = registry.get("bee:approver_policies")
    if not entry then error("approver policies unavailable") end
    local data = object(entry.data)
    data.policies = {{name = "mcp-test", approvers = {ACTOR}, max_ttl_ms = 600000}}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, apply_error = changes:apply()
    if not applied then error(tostring(apply_error)) end
    value(call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "create", title = "Agent access"}))
    local tokens: {[string]: string} = {}
    for _, action in ipairs({"access-a", "access-b"}) do
        value(call("bee.threads.service:admit_action", {thread_id = THREAD, idempotency_key = action, action_id = action,
            admitted = {request_id = action, principal_id = ACTOR, binding_ref = "b", binding_digest = "d", grant_refs = {}, budget_ref = "budget", input = {text = "test"}}}))
        value(call("bee.threads.service:prepare_attempt", {thread_id = THREAD, idempotency_key = action .. "-prepare", action_id = action, attempt_id = action .. "-attempt",
            prepared = {binding_ref = "b", binding_digest = "d", profile_id = "batch", profile_digest = "p", placement_binding = "bee.placement.native.binding:binding", placement_attempt_id = action, plan_digest = "plan"}}))
        local admitted = value(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = action, attempt_id = action .. "-attempt", thread_id = THREAD,
            owner_incarnation = 1, carrier_epoch = 1, workspace_id = WORKSPACE, tools = {"thread_read", "measure_context"}, ttl_ms = 60000,
            surface = {tools = {{name = "measure_context", operation = "bee.gateway.probe:context_tool", description = "Read selected app state",
                policies = {"bee.gateway.probe:context_tool_policy"}, schema = {type = "object", additionalProperties = false}, annotations = {readOnlyHint = true}}},
                traits = {{id = "research:measure", title = "Measure app", prompt = "Read selected app state", tools = {"measure_context"}}},
                base_tools = {"thread_read"}, active_traits = {}, fixed_context = {project = "approved-app"}, dynamic_keys = {"experiment"},
                access = {policy = "mcp-test", traits = {"research:measure"}}}}))
        local binding = object(admitted.binding)
        local authorized = value(call("bee.gateway.binding:authorize_materialization", {attempt_id = action .. "-attempt", carrier_epoch = 1, binding_id = binding.binding_id}))
        local materialized = value(call("bee.gateway.binding:materialize", {attempt_id = action .. "-attempt", carrier_epoch = 1, materialization_key = authorized.materialization_key}))
        local token = bounds.text(materialized.token)
        if not token then error("missing token") end
        tokens[action] = token
    end
    local token = tokens["access-a"]
    assert(rpc(address, "access-a", token, "measure_context", {}).ok == false, "tool available before approval")
    assert(rpc(address, "access-a", token, "session", {operation = "select", expected_revision = 1, active_traits = {"research:measure"}, context = {}}).ok == false, "trait selected without approval")
    local request: Object = {operation = "request_access", idempotency_key = "read-app", traits = {"research:measure"}, reason = "Read benchmark app state"}
    local approval = value(rpc(address, "access-a", token, "session", request))
    local approval_id = bounds.id(approval.approval_id)
    if not approval_id then error("missing approval ID") end
    assert(value(rpc(address, "access-a", token, "session", request)).approval_id == approval_id, "request retry duplicated approval")
    local inbox = value(call("bee.approvals.binding:inbox", {workspace_id = WORKSPACE, after_seq = 0}))
    local encoded_inbox = json.encode(inbox)
    assert(encoded_inbox and encoded_inbox:find(approval_id, 1, true), "pending approval missing from durable inbox")
    assert(value(rpc(address, "access-a", token, "session", {operation = "access_status", approval_id = approval_id})).status == "pending", "pending status")
    assert(rpc(address, "access-b", tokens["access-b"], "session", {operation = "access_status", approval_id = approval_id}).ok == false, "foreign binding inspected approval")
    assert(rpc(address, "access-a", token, "call_tool", {name = "bee.approvals.binding:decide", arguments = {approval_id = approval_id, decision = "approved"}}).ok == false, "MCP approved itself")
    value(call("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = approval.revision, proposal_digest = approval.proposal_digest, decision = "approved"}))
    -- Simulate the durable half of a crash handoff: the approval owner has
    -- consumed the effect, but the gateway has not applied its receipt yet.
    value(call("bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = approval.proposal_digest,
        effect_key = "mcp:" .. approval_id, owner_incarnation = approval.owner_incarnation}))
    assert(rpc(address, "access-a", token, "measure_context", {}).ok == false, "approval consumption alone bypassed gateway admission")
    local granted = value(rpc(address, "access-a", token, "session", {operation = "access_status", approval_id = approval_id}))
    assert(granted.status == "granted", "approved access was not applied")
    assert(value(rpc(address, "access-a", token, "session", {operation = "access_status", approval_id = approval_id})).revision == granted.revision, "grant replay changed revision")
    local measured = value(rpc(address, "access-a", token, "measure_context", {}))
    assert(measured.project == "approved-app" and measured.can_read_gateway == false and measured.can_create_scope == false, "wrong app context or widened native scope")
    assert(rpc(address, "access-b", tokens["access-b"], "measure_context", {}).ok == false, "grant escaped into second binding")
    assert(rpc(address, "access-a", token, "session", {operation = "select", expected_revision = granted.revision, active_traits = {"research:measure"}, context = {project = "another-app"}}).ok == false, "app target changed through dynamic context")
    local deselected = value(rpc(address, "access-a", token, "session", {operation = "select", expected_revision = granted.revision, active_traits = {}, context = {}}))
    assert(value(rpc(address, "access-a", token, "session", {operation = "access_status", approval_id = approval_id})).revision == deselected.revision, "status replay reactivated a deselected trait")
    assert(rpc(address, "access-a", token, "measure_context", {}).ok == false, "status replay reactivated tool")
    local refused = value(rpc(address, "access-b", tokens["access-b"], "session", request))
    assert(refused.approval_id ~= approval_id, "two bindings shared an approval retry key")
    value(call("bee.approvals.binding:decide", {approval_id = refused.approval_id, expected_revision = refused.revision, proposal_digest = refused.proposal_digest, decision = "denied"}))
    local denied = value(rpc(address, "access-b", tokens["access-b"], "session", {operation = "access_status", approval_id = refused.approval_id}))
    assert(denied.status == "denied", "denied approval changed outcome")
    assert(rpc(address, "access-b", tokens["access-b"], "measure_context", {}).ok == false, "denied approval enabled tool")
end
return {run = run}
