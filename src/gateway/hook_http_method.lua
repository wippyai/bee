-- MIT. The hook endpoint in its http form: POST /hook/{action} receives
-- one harness hook event as Claude Code's http hook handler posts it,
-- authenticates the bearer token as a hook credential of the action's
-- binding, and queues the observation. Every answer to the harness is a
-- status with an empty body: an accepted hook is 202 (queued) or 200
-- (already committed), and no refusal ever carries a JSON body, so nothing
-- the gateway says can be read as a hook decision. GET /hook/{action}/{event}
-- answers the submission's status to the same credential.
local http = require("http")
local json = require("json")
local gateway = require("gateway")
local hooks = require("hooks")
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
    local action_id = request:param("action")
    if not action_id or action_id == "" then refuse(response, http.STATUS.NOT_FOUND, "no action"); return nil, nil end
    if request:header("Origin") then refuse(response, http.STATUS.FORBIDDEN, "browser origins are not admitted"); return nil, nil end
    local authorization = request:header("Authorization") or ""
    local token = authorization:match("^Bearer%s+(%S+)$")
    if not token then refuse(response, http.STATUS.UNAUTHORIZED, "bearer token required"); return nil, nil end
    local host = request:host() or ""
    if not gateway.accepts_host(host) then refuse(response, http.STATUS.FORBIDDEN, "host is not the selected listener"); return nil, nil end
    local binding, refusal = gateway.authenticate(token, action_id, "hook")
    if not binding then
        local fault = refusal and refusal.error or {code = "UNAUTHENTICATED", message = "refused"}
        refuse(response, status_of(fault.code), fault.message)
        return nil, nil
    end
    local drain = gateway.draining()
    if drain and drain.past_deadline then refuse(response, http.STATUS.SERVICE_UNAVAILABLE, "the gateway is shutting down"); return nil, nil end
    return binding, action_id
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
    local reply = gateway.submit_hook(binding, body :: Object, "http")
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
