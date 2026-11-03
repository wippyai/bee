local http = require("http")
local json = require("json")
local gateway = require("gateway")
local hooks = require("hooks")
local transport_admission = require("admission")
local boundary = require("session_boundary")
local bounds = require("bounds")
local capabilities = require("capabilities")
local hook_response = require("hook_response")
local funcs = require("funcs")
type Object = {[string]: unknown}
-- A hook command names its event in X-Bee-Hook-Event, optionally qualified by
-- the id of the driver whose declared reader turns the CLI's stdin into the
-- Bee payload and whose response shapes a permission decision.
local EVENT_HEADER = "X-Bee-Hook-Event"
type Command = {event: string, driver: string?}
local function command_of(request: http.Request): (Command?, string?)
    local token = request:header(EVENT_HEADER)
    if token == nil or token == "" then return nil, nil end
    if #token > 192 or not token:match("^[%w_.:-]+$") then return nil, "hook command event is malformed" end
    local driver, event = token:match("^(.+):(%a+)$")
    if not driver then event = token end
    if not hooks.known(tostring(event)) then return nil, "hook command event is not in the hook catalog" end
    return {event = tostring(event), driver = driver}, nil
end
-- command_payload reads a hook command's stdin: the driver's declared reader
-- maps it, or it is the payload itself, whose own event agrees with the
-- command's. The reader reads files of the binding's attempt only. A nil
-- payload with no error is an invocation that holds no work.
local function command_payload(command: Command, raw: string, attempt_id: string): (Object?, string?)
    local reader = command.driver and capabilities.declaration(command.driver).reader or nil
    if reader then
        local reply, call_error = funcs.call(reader, {event = command.event, body = raw, attempt_id = attempt_id})
        local read = bounds.object(reply)
        if call_error or not read then return nil, "hook input reader " .. reader .. " failed: " .. tostring(call_error) end
        if read.skip == true then return nil, nil end
        local payload = bounds.object(read.payload)
        if not payload then return nil, tostring(read.error or "hook input reader returned no payload") end
        return payload, nil
    end
    local decoded: unknown, decode_error = json.decode(raw)
    local payload = bounds.object(decoded)
    if decode_error or not payload then return nil, "hook input is not a JSON object" end
    for _, name in ipairs({"hook_event_name", "event"}) do
        if payload[name] ~= nil and payload[name] ~= command.event then return nil, "hook input event conflicts with the command event" end
    end
    payload.hook_event_name = command.event
    return payload, nil
end
local function refuse(response: http.Response, status: number, message: string): nil
    response:set_content_type("text/plain; charset=utf-8")
    response:set_status(status)
    response:write(message .. "\n")
    return nil
end
local function status_of(code: string): number
    if code == "INVALID" then return http.STATUS.BAD_REQUEST end
    if code == "DENIED" then return http.STATUS.FORBIDDEN end
    if code == "CONFLICT" or code == "STALE" then return http.STATUS.CONFLICT end
    if code == "NOT_FOUND" then return http.STATUS.NOT_FOUND end
    if code == "UNAVAILABLE" then return http.STATUS.SERVICE_UNAVAILABLE end
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
    local request = http.request({max_body = hooks.MAX_PAYLOAD_BYTES})
    local response = http.response()
    if not request or not response then return nil end
    local binding = admitted(request, response)
    if not binding then return nil end
    local raw, read_error = request:body()
    if read_error and read_error:kind() == errors.INVALID then refuse(response, 413, "hook payload exceeds " .. tostring(hooks.MAX_PAYLOAD_BYTES) .. " bytes"); return nil end
    if read_error or not raw then refuse(response, http.STATUS.BAD_REQUEST, "hook payload is unreadable"); return nil end
    local command, command_error = command_of(request)
    if command_error then refuse(response, http.STATUS.BAD_REQUEST, command_error); return nil end
    local payload: Object? = nil
    if command then
        local read_error: string? = nil
        payload, read_error = command_payload(command, raw, binding.attempt_id)
        if read_error then refuse(response, http.STATUS.BAD_REQUEST, read_error); return nil end
        if not payload then response:set_status(http.STATUS.OK); return nil end
    else
        local body: unknown, body_error = json.decode(raw)
        if body_error or type(body) ~= "table" then refuse(response, http.STATUS.BAD_REQUEST, "hook payload is not a JSON object"); return nil end
        payload = bounds.object(body)
        if not payload then refuse(response, http.STATUS.BAD_REQUEST, "hook payload must be an object"); return nil end
    end
    local reply = gateway.submit_hook(binding, payload, "http")
    if not reply.ok then
        local fault = reply.error or {code = "STORAGE", message = "hook"}
        if fault.code == "OVERLOAD" then response:set_header("Retry-After", tostring(math.ceil(hooks.RETRY_AFTER_MS / 1000))) end
        refuse(response, status_of(fault.code), fault.message)
        return nil
    end
    local outcome = reply.value
    response:set_header("X-Bee-Event", tostring(outcome.event_id))
    -- A replay of a terminally rejected occurrence is told so with a status
    -- and plain text, never a body a harness could act on.
    if outcome.status == "rejected" then refuse(response, http.STATUS.GONE, "rejected: " .. tostring(outcome.rejected_reason or "no reason")); return nil end
    local context, boundary_error = boundary.deliver(binding, outcome, payload, "hook_http")
    if not context then
        local refused = boundary_error or {code = "INTERNAL", message = "session boundary failed"}
        refuse(response, status_of(refused.code), refused.code .. ": " .. refused.message)
        return nil
    end
    if command and command.driver and command.event == "PermissionRequest" and next(context) ~= nil then
        local shaped, shape_error = hook_response.permission(context, command.driver)
        if not shaped then refuse(response, http.STATUS.INTERNAL_ERROR, "permission response: " .. tostring(shape_error)); return nil end
        context = shaped
    end
    if next(context) ~= nil then response:set_content_type(http.CONTENT.JSON) end
    if outcome.status == "committed" then response:set_status(http.STATUS.OK) else response:set_status(http.STATUS.ACCEPTED) end
    if next(context) ~= nil then response:write_json(context) end
    return nil
end
local function status(): nil
    local request = http.request()
    local response = http.response()
    if not request or not response then return nil end
    local binding = admitted(request, response)
    if not binding then return nil end
    local event_id = request:param("event") or ""
    if event_id == "" or #event_id > 128 then refuse(response, http.STATUS.BAD_REQUEST, "event id required"); return nil end
    local reply = gateway.hook_status(binding, event_id)
    if not reply.ok then
        local fault = reply.error or {code = "STORAGE", message = "hook"}
        refuse(response, status_of(fault.code), fault.message)
        return nil
    end
    response:set_content_type(http.CONTENT.JSON)
    response:set_status(http.STATUS.OK)
    response:write_json(reply.value)
    return nil
end
return {submit = submit, status = status}
