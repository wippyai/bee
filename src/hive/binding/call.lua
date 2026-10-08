-- MIT
local access = require("access")
local outbound = require("outbound")
local protocol = require("protocol")
local application = require("application")
local bounds = require("bounds")
local security = require("security")
local registry = require("registry")
local schemas = require("schemas")
local operations = require("operations")
local time = require("time")
local canonical = require("canonical")
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end
local function call(raw: unknown): Reply
    local asked = bounds.object(raw)
    if asked and type(asked.application) == "string" then
        for _, entry in ipairs(application.host_entries("bee.hive.host_exposure")) do
            local data = bounds.object(entry.data)
            if data and data.application_ref == asked.application then
                if bounds.fields(asked, {"node", "workspace_id", "application", "service", "operation", "arguments", "timeout", "idempotency_key"}) then return fail("INVALID", "Hive call request is malformed") end
                local node, action = bounds.id(asked.node), bounds.id(data.outbound_action)
                if not node or not action or not security.can(action, node) then return fail("DENIED", "peer session calls require the caller's session permission") end
                local refs = bounds.ids(data.operations, true)
                local selected: operations.Operation? = nil
                for _, ref in ipairs(refs or {}) do
                    local op, err = operations.decode(registry.get(ref), true)
                    if err then return fail("INVALID", err) end
                    if op and op.service == asked.service and op.name == asked.operation then
                        if selected then return fail("INVALID", "duplicate host operation") end
                        selected = op
                    end
                end
                if not selected then return fail("INVALID", "unknown host operation") end
                local timeout = asked.timeout == nil and "30s" or bounds.line(asked.timeout, 32)
                local duration = timeout and time.parse_duration(timeout)
                local workspace = asked.workspace_id == nil and nil or bounds.id(asked.workspace_id)
                if not duration or duration:nanoseconds() <= 0 or duration:nanoseconds() > 30000000000
                    or (asked.workspace_id ~= nil and not workspace) or not canonical.encode(asked, protocol.MAX_BYTES) then
                    return fail("INVALID", "Hive call target or deadline is malformed")
                end
                local arguments = bounds.object(asked.arguments)
                if not arguments then return fail("INVALID", "host call requires arguments") end
                local input_error = schemas.validate(selected.input, arguments)
                if input_error then return fail("INVALID", input_error) end
                if selected.effect == "mutation" and (asked.idempotency_key == nil or asked.idempotency_key ~= arguments.operation_key) then
                    return fail("INVALID", "mutation idempotency_key must equal operation_key")
                end
                local uncertain = selected.effect == "mutation" and "UNKNOWN_OUTCOME" or "UNAVAILABLE"
                local reply, err = protocol.call(node, "application.call", {application = asked.application, workspace_id = asked.workspace_id,
                    service = asked.service, operation = asked.operation, arguments = arguments, idempotency_key = asked.idempotency_key}, tostring(timeout), true)
                if not reply then return fail(uncertain, tostring(err)) end
                if not reply.ok then
                    local message = tostring(reply.error)
                    return fail(message:find("outcome unknown", 1, true) and uncertain or "DENIED", message)
                end
                local result, result_error = outbound.result(reply)
                if result_error then return fail(uncertain, result_error) end
                return {ok = true, value = result}
            end
        end
    end
    local caller, record, live, refusal = access.granted()
    if refusal then return refusal end
    local identity = bounds.object(caller)
    if not identity or not record then return fail("DENIED", "application identity is unavailable") end
    local binding, admitted, admission_error = application.admission(tostring(identity.definition_id), tostring(identity.workspace_id))
    if not binding then return fail("DENIED", "source application admission is absent or revoked: " .. tostring(admission_error)) end
    if admitted and admitted.overlay_owner ~= record.overlay_owner then return fail("DENIED", "source admission and grant ownership differ") end
    local request, err = outbound.authorize(raw, record, caller, live)
    if not request then return fail("DENIED", tostring(err)) end
    local reply, call_error = protocol.call(request.node, "application.call", request.args, request.timeout, true)
    if not reply then return fail("UNAVAILABLE", tostring(call_error)) end
    local value, result_error = outbound.result(reply)
    if result_error then return fail("FAILED", result_error) end
    return {ok = true, value = value, error = nil}
end
return {call = call}
