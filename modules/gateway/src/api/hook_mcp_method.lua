local http = require("http")
local json = require("json")
local gateway = require("gateway")
local mcp = require("mcp")
local hooks = require("hooks")
local hook_inbox = require("hook_inbox")
type Object = {[string]: unknown}
local function answer(response: http.Response, status: number, body: Object)
    response:set_status(status)
    response:set_content_type(http.CONTENT.JSON)
    response:write_json(body)
end
local HOOK_TOOL = {name = "hook", description = "Submit one hook observation about this attempt; it is recorded, never answered with a decision. "
    .. "event names the closed hook catalog event; identity fields correlate the occurrence; "
    .. "content fields keep only sizes and digests, never text",
    inputSchema = hooks.schema(), annotations = mcp.WRITE_ANNOTATIONS,
    outputSchema = {type = "object", additionalProperties = false, required = {"ok"},
        properties = {ok = {type = "boolean"}, value = {type = "object"},
            error = {type = "object", additionalProperties = false,
                properties = {code = {type = "string"}, message = {type = "string"},
                    field = {type = "string"}, retryable = {type = "boolean"}, remedy = {type = "string"}}}}}}
local function handle(): nil
    local request = http.request()
    local response = http.response()
    if not request or not response then return nil end
    local action_id = request:param("action")
    if not action_id or action_id == "" then answer(response, http.STATUS.NOT_FOUND, mcp.failure(nil, mcp.INVALID_REQUEST, "no action")); return nil end
    if request:header("Origin") then answer(response, http.STATUS.FORBIDDEN, mcp.failure(nil, mcp.INVALID_REQUEST, "browser origins are not admitted")); return nil end
    local authorization = request:header("Authorization") or ""
    local token = authorization:match("^Bearer%s+(%S+)$")
    if not token then answer(response, http.STATUS.UNAUTHORIZED, mcp.failure(nil, mcp.INVALID_REQUEST, "bearer token required")); return nil end
    local host = request:host() or ""
    if not gateway.accepts_host(host) then answer(response, http.STATUS.FORBIDDEN, mcp.failure(nil, mcp.INVALID_REQUEST, "host is not the selected listener")); return nil end
    local binding, refusal = gateway.authenticate(token, action_id, "hook")
    if not binding then
        local fault = refusal and refusal.error or {code = "UNAUTHENTICATED", message = "refused"}
        local status = fault.code == "DENIED" and http.STATUS.FORBIDDEN or (fault.code == "STORAGE" and http.STATUS.INTERNAL_ERROR or http.STATUS.UNAUTHORIZED)
        answer(response, status, mcp.failure(nil, mcp.INVALID_REQUEST, fault.message)); return nil
    end
    local drain = gateway.draining()
    if drain and drain.past_deadline then answer(response, http.STATUS.SERVICE_UNAVAILABLE, mcp.failure(nil, mcp.INVALID_REQUEST, "the gateway is shutting down")); return nil end
    local raw = request:body() or ""
    if #raw > hooks.MAX_PAYLOAD_BYTES then answer(response, 413, mcp.failure(nil, mcp.INVALID_REQUEST, "hook payload exceeds " .. tostring(hooks.MAX_PAYLOAD_BYTES) .. " bytes")); return nil end
    local body: unknown, body_error = json.decode(raw)
    if body_error then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.PARSE_ERROR, "body is not JSON")); return nil end
    local call, decode_error = mcp.decode(body)
    if not call then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.INVALID_REQUEST, decode_error or "invalid request")); return nil end
    if call.notification then response:set_status(http.STATUS.ACCEPTED); return nil end
    if call.method == "initialize" then answer(response, http.STATUS.OK, mcp.result(call.id, mcp.initialize())); return nil end
    if call.method == "tools/list" then answer(response, http.STATUS.OK, mcp.result(call.id, {tools = {HOOK_TOOL}})); return nil end
    if call.method ~= "tools/call" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.METHOD_NOT_FOUND, "method not found")); return nil end
    if call.params.name ~= "hook" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "only the hook tool is served here")); return nil end
    local class, reason = hooks.classify(call.params._meta)
    if class ~= "hook_engine" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "request metadata is not a hook-engine call (" .. class .. "): " .. reason)); return nil end
    local arguments = call.params.arguments
    if type(arguments) ~= "table" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "arguments must be an object")); return nil end
    local reply = gateway.submit_hook(binding, arguments :: Object, "codex:" .. class)
    if not reply.ok then
        local fault = reply.error or {code = "STORAGE", message = "hook"}
        answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, fault.code .. ": " .. fault.message)); return nil
    end
    -- Codex reads a hook tool's text content as hook stdout: Stop requires
    -- JSON there, and other events turn plain text into model context. A
    -- recorded boundary event may answer with the bound action's
    -- outstanding inbox as that text. The read runs as the binding's
    -- subject; a failure degrades to the proven empty content instead of
    -- breaking the harness loop.
    local outcome = reply.value :: Object
    local event: string? = nil
    if type(arguments.event) == "string" then event = arguments.event
    elseif type(arguments.hook_event_name) == "string" then event = arguments.hook_event_name end
    local content = table.create(1, 0)
    local carried = hook_inbox.carry_text(event, hook_inbox.context(binding, event))
    if carried then content = {{type = "text", text = carried}} end
    answer(response, http.STATUS.OK, mcp.result(call.id, {content = content,
        structuredContent = {status = outcome.status, event_id = outcome.event_id}, isError = false}))
    return nil
end
return {handle = handle}
