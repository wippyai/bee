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
local gateway = require("gateway")
local mcp = require("mcp")
type Object = {[string]: unknown}
local function scope_for(names: {string}): (security.Scope?, string?)
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then return nil, "policy " .. name .. " unavailable" end
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
local function subject_executor(binding: gateway.Binding, tool: mcp.Tool): (funcs.Executor?, Object?)
    local scope, scope_error = scope_for(tool.policies)
    if not scope then return nil, refused("UNAVAILABLE", scope_error or "scope") end
    local subject, subject_error = security.new_actor(binding.subject)
    if not subject then return nil, refused("DENIED", tostring(subject_error)) end
    local acted, actor_error = funcs.new():with_actor(subject)
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
local function run(binding: gateway.Binding, tool: mcp.Tool, request: Object): Object
    if tool.name == "thread_read" or tool.name == "thread_message" then
        request.thread_id = binding.thread_id
    end
    if tool.name == "thread_message" then
        request.kind = "message"
        request.context = {action_id = binding.action_id, attempt_id = binding.attempt_id}
    end
    local executor, failure = subject_executor(binding, tool)
    if not executor then return failure :: Object end
    local reply, call_error = executor:call(tool.operation, request)
    return reply_result(reply, call_error)
end
local function wait(binding: gateway.Binding, tool: mcp.Tool, request: Object): Object
    request.thread_id = binding.thread_id
    local executor, failure = subject_executor(binding, tool)
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
    if call.method == "tools/list" then answer(response, http.STATUS.OK, mcp.result(call.id, mcp.list(binding.tools))); return nil end
    if call.method ~= "tools/call" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.METHOD_NOT_FOUND, "method not found")); return nil end
    local name = call.params.name
    if type(name) ~= "string" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "tool name required")); return nil end
    local admitted = false
    for _, allowed in ipairs(binding.tools) do if allowed == name then admitted = true end end
    local tool = mcp.tool(name :: string)
    if not tool or not admitted then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "tool is not admitted for this binding")); return nil end
    local arguments: Object? = nil
    local argument_error: string? = nil
    if tool.name == "thread_read" then arguments, argument_error = mcp.read_arguments(call.params)
    elseif tool.name == "thread_wait" then arguments, argument_error = mcp.wait_arguments(call.params)
    elseif tool.name == "thread_message" then arguments, argument_error = mcp.message_arguments(call.params)
    else arguments, argument_error = mcp.workspace_arguments(call.params) end
    if not arguments then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, argument_error or "invalid arguments")); return nil end
    if tool.name == "thread_wait" then answer(response, http.STATUS.OK, mcp.result(call.id, wait(binding, tool, arguments)))
    else answer(response, http.STATUS.OK, mcp.result(call.id, run(binding, tool, arguments))) end
    return nil
end
return {handle = handle}
