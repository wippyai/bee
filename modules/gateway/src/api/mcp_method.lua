-- MIT. The MCP endpoint: POST /mcp/{action}. It authenticates the bearer
-- token against the action, decodes one JSON-RPC request, and maps a tool
-- call to one owner operation run as the bound subject under host-named
-- policies. It writes no record itself; the thread owner authorizes again.
-- A wait runs in bounded slices so drain releases it with an explicit
-- outcome, and past the host's drain deadline nothing is served.
local http = require("http")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local gateway = require("gateway")
local mcp = require("mcp")
local catalog = require("catalog")
local context = require("context")
local bounds = require("bounds")
type Object = {[string]: unknown}
type RuntimeGrant = {access_approval_id: string, access_proposal_digest: string, surface_revision: integer, surface_digest: string}
local function selected_policy(reference: string): (string?, string?)
    if not mcp.is_tool_policy_reference(reference) then return reference, nil end
    local entry, entry_error = registry.get(reference)
    if entry_error or not entry then return nil, "built-in tool policy reference is unavailable" end
    local data = bounds.object(entry.data)
    local selected = data and bounds.id(data.resource_ref)
    if not selected then return nil, "built-in tool policy is not linked by the host" end
    return selected, nil
end
local function scope_for(names: {string}): (security.Scope?, string?)
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local selected, selected_error = selected_policy(name)
        if not selected then return nil, selected_error or "tool policy is unavailable" end
        local policy, err = security.policy(selected)
        if err or not policy then return nil, "policy " .. selected .. " unavailable" end
        policies[index] = policy
    end
    return security.new_scope(policies), nil
end
local function answer(response: http.Response, status: number, body: Object)
    response:set_status(status)
    response:set_content_type(http.CONTENT.JSON)
    response:write_json(body)
end
local function refused(code: string, message: string): Object
    return mcp.tool_result(json.encode({ok = false, error = {code = code, message = message}}) or "{}", true)
end
-- The executor that runs a tool as the bound subject under the tool's
-- host-named scope. The endpoint's own right to invoke these operations
-- is a separate grant; membership is the thread owner's decision.
local function subject_executor(binding: gateway.Binding, tool: mcp.Tool, values: Object?, runtime: RuntimeGrant?): (funcs.Executor?, Object?)
    local scope, scope_error = scope_for(tool.policies)
    if not scope then return nil, refused("UNAVAILABLE", scope_error or "scope") end
    -- The subject acts only in its binding's workspace: workspace-scoped
    -- policies compare the resource with this host-derived metadata.
    local subject_meta: {[string]: string} = {}
    if binding.workspace_id then subject_meta.workspace_id = binding.workspace_id end
    local subject, subject_error = security.new_actor(binding.subject, subject_meta)
    if not subject then return nil, refused("DENIED", tostring(subject_error)) end
    local executor = funcs.new()
    local attributed, attribution_error = context.bind(values, {binding_id = binding.binding_id,
        thread_id = binding.thread_id, subject = binding.subject, action_id = binding.action_id, attempt_id = binding.attempt_id,
        policy_ref = binding.policy_ref, workspace_id = binding.workspace_id, origin_view = binding.origin_view,
        application_runtime = runtime and {thread_id = binding.thread_id, subject = binding.subject, initiating_owner = binding.subject,
            binding_id = binding.binding_id, access_approval_id = runtime.access_approval_id :: string,
            access_proposal_digest = runtime.access_proposal_digest :: string, surface_revision = runtime.surface_revision :: integer,
            surface_digest = runtime.surface_digest :: string} or nil})
    if not attributed then return nil, refused("DENIED", tostring(attribution_error)) end
    local contextual, context_error = executor:with_context(attributed)
    if not contextual then return nil, refused("DENIED", tostring(context_error)) end
    executor = contextual
    local acted, actor_error = executor:with_actor(subject)
    if not acted then return nil, refused("DENIED", tostring(actor_error)) end
    local scoped, scoped_error = acted:with_scope(scope)
    if not scoped then return nil, refused("DENIED", tostring(scoped_error)) end
    return scoped, nil
end
local function reply_result(reply: unknown, call_error: unknown): Object
    if call_error then return refused("UNAVAILABLE", tostring(call_error)) end
    local encoded = json.encode(reply) or "{}"
    local is_error = type(reply) ~= "table" or (reply :: Object).ok ~= true
    return mcp.tool_result(encoded, is_error)
end
local function run(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object, runtime: RuntimeGrant?): Object
    if tool.name == "thread_read" or tool.name == "thread_message" then
        request.thread_id = binding.thread_id
    end
    if tool.name == "thread_message" then
        request.kind = "message"
        request.context = {action_id = binding.action_id, attempt_id = binding.attempt_id}
    end
    local executor, failure = subject_executor(binding, tool, values, runtime)
    if not executor then return failure :: Object end
    local reply, call_error = executor:call(tool.operation, request)
    return reply_result(reply, call_error)
end
local function wait(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object): Object
    request.thread_id = binding.thread_id
    local executor, failure = subject_executor(binding, tool, values, nil)
    if not executor then return failure :: Object end
    local remaining = tonumber(request.wait_ms) or 0
    local budget = tonumber(request.transport_budget_ms) or mcp.TRANSPORT_BUDGET_MS
    if remaining > budget then remaining = budget end
    local outcome: Object? = nil
    while not outcome do
        local drain = gateway.draining()
        if drain and drain.draining then
            outcome = mcp.tool_result(json.encode({ok = true, value = {status = "released", reason = "draining", scanned_through = request.after_sequence}}) or "{}", false)
        else
            local slice = math.floor(math.min(remaining, gateway.WAIT_SLICE_MS))
            local sliced: Object = {thread_id = request.thread_id, after_sequence = request.after_sequence, wait_ms = slice, transport_budget_ms = budget}
            local reply, call_error = executor:call(tool.operation, sliced)
            if call_error then
                outcome = refused("UNAVAILABLE", tostring(call_error))
            else
                local value = type(reply) == "table" and (reply :: Object).value or nil
                local status = type(value) == "table" and tostring((value :: Object).status) or ""
                remaining = remaining - slice
                if status ~= "timeout" or remaining <= 0 then outcome = reply_result(reply, nil) end
            end
        end
    end
    return outcome
end
local function handle(): nil
    local request, request_error = http.request({max_body = mcp.MAX_BODY_BYTES})
    local response = http.response()
    if not request or not response then return nil end
    if request_error then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.INVALID_REQUEST, "unreadable request")); return nil end
    local action_id = request:param("action")
    if not action_id or action_id == "" then answer(response, http.STATUS.NOT_FOUND, mcp.failure(nil, mcp.INVALID_REQUEST, "no action")); return nil end
    if request:header("Origin") then answer(response, http.STATUS.FORBIDDEN, mcp.failure(nil, mcp.INVALID_REQUEST, "browser origins are not admitted")); return nil end
    local authorization = request:header("Authorization") or ""
    local token = authorization:match("^Bearer%s+(%S+)$")
    if not token then answer(response, http.STATUS.UNAUTHORIZED, mcp.failure(nil, mcp.INVALID_REQUEST, "bearer token required")); return nil end
    local host = request:host() or ""
    if not gateway.accepts_host(host) then
        answer(response, http.STATUS.FORBIDDEN, mcp.failure(nil, mcp.INVALID_REQUEST, "host is not the selected listener")); return nil
    end
    local binding, refusal = gateway.authenticate(token, action_id, "tool")
    if not binding then
        local fault = refusal and refusal.error or {code = "UNAUTHENTICATED", message = "refused"}
        local status = fault.code == "DENIED" and http.STATUS.FORBIDDEN or (fault.code == "STORAGE" and http.STATUS.INTERNAL_ERROR or http.STATUS.UNAUTHORIZED)
        answer(response, status, mcp.failure(nil, mcp.INVALID_REQUEST, fault.message)); return nil
    end
    local drain = gateway.draining()
    if drain and drain.past_deadline then answer(response, http.STATUS.SERVICE_UNAVAILABLE, mcp.failure(nil, mcp.INVALID_REQUEST, "the gateway is shutting down")); return nil end
    local body, body_error = request:body_json()
    if body_error then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.PARSE_ERROR, "body is not JSON")); return nil end
    local call, decode_error = mcp.decode(body)
    if not call then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.INVALID_REQUEST, decode_error or "invalid request")); return nil end
    if call.notification then
        response:set_status(http.STATUS.ACCEPTED)
        return nil
    end
    if call.method == "initialize" then answer(response, http.STATUS.OK, mcp.result(call.id, mcp.initialize())); return nil end
    if call.method == "notifications/initialized" or call.method == "ping" then answer(response, http.STATUS.OK, mcp.result(call.id, {})); return nil end
    local bound, surface_error = gateway.surface(binding)
    if not bound then answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(surface_error, nil))); return nil end
    local config = bound.configuration
    local available, available_error = catalog.select(config.catalog, config.ceiling, config.base_tools, config.allowed_traits, bound.selection.active)
    if not available then answer(response, http.STATUS.OK, mcp.result(call.id, refused("DENIED", available_error or "surface is unavailable"))); return nil end
    local values, values_error = context.compose(config.fixed_context, bound.selection.context, config.dynamic_keys)
    if not values then answer(response, http.STATUS.OK, mcp.result(call.id, refused("DENIED", values_error or "context is unavailable"))); return nil end
    local described: {Object} = {}
    for _, item in ipairs(available) do described[#described + 1] = {name = item.name, description = item.description, inputSchema = item.schema, annotations = item.annotations} end
    if call.method == "tools/list" then
        local listed: {Object} = {}
        for _, item in ipairs(described) do listed[#listed + 1] = item end
        listed[#listed + 1] = {name = "session", description = "Read or select traits/context. Request host-declared access with request_access, then poll access_status with its approval_id; only an approved request enables access for this agent.",
            inputSchema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
                operation = {type = "string", enum = {"read", "select", "request_access", "access_status"}}, expected_revision = {type = "integer", minimum = 1},
                active_traits = {type = "array", items = {type = "string"}}, context = {type = "object"},
                idempotency_key = {type = "string"}, traits = {type = "array", items = {type = "string"}}, reason = {type = "string", maxLength = 1024}, approval_id = {type = "string"}}}}
        listed[#listed + 1] = {name = "call_tool", description = "Call a currently active tool by name. Use session read for current schemas after changing traits; admission is checked on every call.",
            inputSchema = {type = "object", additionalProperties = false, required = {"name", "arguments"}, properties = {name = {type = "string"}, arguments = {type = "object"}}}}
        answer(response, http.STATUS.OK, mcp.result(call.id, {tools = listed})); return nil
    end
    if call.method ~= "tools/call" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.METHOD_NOT_FOUND, "method not found")); return nil end
    local name = call.params.name
    if type(name) ~= "string" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "tool name required")); return nil end
    if name == "session" then
        local request = bounds.object(call.params.arguments)
        if not request then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "session arguments required")); return nil end
        local allowed: {string} = {"operation"}
        if request.operation == "request_access" then allowed = {"operation", "idempotency_key", "traits", "reason"}
        elseif request.operation == "access_status" then allowed = {"operation", "approval_id"}
        elseif request.operation ~= "read" then allowed = {"operation", "expected_revision", "active_traits", "context"} end
        local extra = bounds.fields(request, allowed)
        if extra then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, extra)); return nil end
        if request.operation == "request_access" then
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(gateway.request_access(binding,
                {idempotency_key = request.idempotency_key, traits = request.traits, reason = request.reason}), nil))); return nil
        end
        if request.operation == "access_status" then
            local approval_id = bounds.id(request.approval_id)
            if not approval_id then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "approval_id required")); return nil end
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(gateway.access_status(binding, approval_id), nil))); return nil
        end
        if request.operation == "read" then
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result({ok = true, value = {revision = bound.revision,
                traits = config.catalog.traits, requestable_access = config.access, allowed_traits = config.allowed_traits, active_traits = bound.selection.active, context = bound.selection.context,
                dynamic_keys = config.dynamic_keys, tools = described}}, nil))); return nil
        end
        local revision = bounds.count(request.expected_revision)
        if request.operation ~= "select" or not revision or revision < 1 then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "select needs a positive expected_revision")); return nil end
        answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(gateway.select_surface(binding, revision, request.active_traits, request.context), nil))); return nil
    end
    local parameters = call.params
    if name == "call_tool" then
        local forwarded = bounds.object(call.params.arguments)
        if not forwarded or bounds.fields(forwarded, {"name", "arguments"}) or type(forwarded.name) ~= "string" then
            answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "call_tool needs name and arguments")); return nil
        end
        name = forwarded.name
        parameters = {arguments = forwarded.arguments}
    end
    local tool: mcp.Tool? = nil
    for _, item in ipairs(available) do if item.name == name then tool = item end end
    if not tool then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "tool is not admitted for this binding")); return nil end
    local arguments: Object? = nil
    local argument_error: string? = nil
    if tool.name == "thread_read" then arguments, argument_error = mcp.read_arguments(parameters)
    elseif tool.name == "thread_wait" then arguments, argument_error = mcp.wait_arguments(parameters)
    elseif tool.name == "thread_message" then arguments, argument_error = mcp.message_arguments(parameters)
    elseif tool.name == "thread_launch" then arguments, argument_error = mcp.launch_arguments(parameters)
    elseif tool.name == "overlay" then arguments, argument_error = mcp.overlay_arguments(parameters)
    elseif tool.name == "docs" then arguments, argument_error = mcp.docs_arguments(parameters)
    elseif tool.name == "components" then arguments, argument_error = mcp.components_arguments(parameters)
    elseif tool.name == "delivery" then arguments, argument_error = mcp.delivery_arguments(parameters)
    elseif tool.name == "publish" then arguments, argument_error = mcp.publish_arguments(parameters)
    elseif tool.name == "application_open" then arguments, argument_error = mcp.open_arguments(parameters)
    else arguments = bounds.object(parameters.arguments); if not arguments then argument_error = "tool arguments must be an object" end end
    if not arguments then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, argument_error or "invalid arguments")); return nil end
    local runtime: RuntimeGrant? = nil
    if tool.name == "application_open" then
        local granted, grant_failure = gateway.application_runtime(binding, bound)
        if not granted then
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(grant_failure, nil)))
            return nil
        end
        runtime = granted
    end
    if tool.name == "thread_wait" then answer(response, http.STATUS.OK, mcp.result(call.id, wait(binding, tool, arguments, values)))
    else answer(response, http.STATUS.OK, mcp.result(call.id, run(binding, tool, arguments, values, runtime))) end
    return nil
end
return {handle = handle}
