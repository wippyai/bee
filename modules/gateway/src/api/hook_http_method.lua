local http = require("http")
local json = require("json")
local gateway = require("gateway")
local hooks = require("hooks")
local transport_admission = require("admission")
local boundary = require("session_boundary")
local bounds = require("bounds")
type Object = {[string]: unknown}
local function refuse(response: http.Response, status: number, message: string): nil
    response:set_content_type("text/plain; charset=utf-8")
    response:set_status(status)
    response:write(message .. "\n")
    return nil
end
local function status_of(code: string): number
    if code == "INVALID" then return http.STATUS.BAD_REQUEST end
    if code == "DENIED" then return http.STATUS.FORBIDDEN end
    if code == "CONFLICT" then return http.STATUS.CONFLICT end
    if code == "UNAUTHENTICATED" then return http.STATUS.UNAUTHORIZED end
    if code == "OVERLOAD" then return http.STATUS.TOO_MANY_REQUESTS end
    return http.STATUS.INTERNAL_ERROR
end
local function admitted(request: http.Request, response: http.Response): (gateway.Binding?, string?)
    local result = transport_admission.check(request, "hook")
    if not result.ok then refuse(response, result.status, result.message); return nil, nil end
    return result.binding, result.action_id
end
local function submit(): nil
    local request = http.request()
    local response = http.response()
    if not request or not response then return nil end
    local binding = admitted(request, response)
    if not binding then return nil end
    local raw = request:body() or ""
    if #raw > hooks.MAX_PAYLOAD_BYTES then return refuse(response, 413, "hook payload exceeds " .. tostring(hooks.MAX_PAYLOAD_BYTES) .. " bytes") end
    local body: unknown, body_error = json.decode(raw)
    if body_error or type(body) ~= "table" then return refuse(response, http.STATUS.BAD_REQUEST, "hook payload is not a JSON object") end
    local payload = bounds.object(body)
    if not payload then return refuse(response, http.STATUS.BAD_REQUEST, "hook payload must be an object") end
    local reply = gateway.submit_hook(binding, payload, "http")
    if not reply.ok then
        local fault = reply.error or {code = "STORAGE", message = "hook"}
        if fault.code == "OVERLOAD" then response:set_header("Retry-After", tostring(math.ceil(hooks.RETRY_AFTER_MS / 1000))) end
        return refuse(response, status_of(fault.code), fault.message)
    end
    local outcome = reply.value :: Object
    response:set_header("X-Bee-Event", tostring(outcome.event_id))
    -- A replay of a terminally rejected occurrence is told so with a status
    -- and plain text, never a body a harness could act on.
    if outcome.status == "rejected" then return refuse(response, http.STATUS.GONE, "rejected: " .. tostring(outcome.rejected_reason or "no reason")) end
    local context, boundary_error = boundary.deliver(binding, outcome, payload, "hook_http")
    if not context then return refuse(response, http.STATUS.INTERNAL_ERROR, boundary_error or "session boundary failed") end
    if context.hookSpecificOutput ~= nil then response:set_content_type(http.CONTENT.JSON); response:write_json(context) end
    if outcome.status == "committed" then response:set_status(http.STATUS.OK) else response:set_status(http.STATUS.ACCEPTED) end
    return nil
end
local function status(): nil
    local request = http.request()
    local response = http.response()
    if not request or not response then return nil end
    local binding = admitted(request, response)
    if not binding then return nil end
    local event_id = request:param("event") or ""
    if event_id == "" or #event_id > 128 then return refuse(response, http.STATUS.BAD_REQUEST, "event id required") end
    local reply = gateway.hook_status(binding, event_id)
    if not reply.ok then
        local fault = reply.error or {code = "STORAGE", message = "hook"}
        return refuse(response, status_of(fault.code), fault.message)
    end
    response:set_content_type(http.CONTENT.JSON)
    response:set_status(http.STATUS.OK)
    response:write_json(reply.value)
    return nil
end
return {submit = submit, status = status}
