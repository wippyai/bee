-- MIT
local protocol = require("protocol")
local bounds = require("bounds")
local outbound = require("outbound")
local schemas = require("schemas")
local declarations = require("declarations")
local M = {}
type Object = {[string]: unknown}
type Failure = {code: string, message: string, field: string?, retryable: boolean?, remedy: string?}
type Reply = {ok: boolean, value: unknown, error: Failure?}
local FAILURE_FIELDS = {"code", "message", "field", "retryable", "remedy"}

local function failure(raw: unknown): Failure?
    local object = bounds.object(raw)
    if not object or bounds.fields(object, FAILURE_FIELDS) then return nil end
    local code, message = object.code, object.message
    if type(code) ~= "string" or type(message) ~= "string" then return nil end
    local field, remedy, retryable = object.field, object.remedy, object.retryable
    if (field ~= nil and type(field) ~= "string") or (remedy ~= nil and type(remedy) ~= "string")
        or (retryable ~= nil and type(retryable) ~= "boolean") then
        return nil
    end
    return {code = code, message = message, field = field, retryable = retryable, remedy = remedy}
end

-- reply decodes the reply envelope an application tool or test run returns.
function M.reply(raw: unknown): Reply?
    local object = bounds.object(raw)
    if not object or bounds.fields(object, {"ok", "value", "error"}) then return nil end
    if object.ok == true then
        if object.error ~= nil then return nil end
        return {ok = true, value = object.value, error = nil}
    end
    if object.ok ~= false or object.value ~= nil then return nil end
    local reason = failure(object.error)
    if not reason then return nil end
    return {ok = false, value = nil, error = reason}
end

local function fail(message: string): Reply
    return {ok = false, value = nil, error = {code = "UNAVAILABLE", message = message}}
end
function M.tools(request: Object): Reply
    local node = assert(bounds.id(request.node))
    local reply, err = protocol.call(node, "application.discover", {}, "10s", true)
    if not reply then return fail(tostring(err)) end
    if not reply.ok then return fail(reply.error or "remote discovery failed") end
    if request.operation == "list" then return {ok = true, value = reply.value, error = nil} end
    local rows = reply.value and reply.value.tools
    local selected: Object? = nil
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row = bounds.object(raw)
        if row and row.alias == request.tool then
            if selected then return fail("remote tool is ambiguous") end
            selected = row
        end
    end
    if not selected then return fail("remote peer offers no exposed tool " .. tostring(request.tool)) end
    local input = bounds.object(selected.input_schema)
    local output = bounds.object(selected.output_schema)
    if not input or not declarations.valid_definition(input) or (output and not declarations.valid_definition(output)) then
        return fail("invalid remote tool contract")
    end
    local invalid = schemas.validate(input, request.arguments)
    if invalid then return fail(invalid) end
    local called, call_error = protocol.call(node, "application.call", {application = selected.definition_id,
        workspace_id = selected.workspace_id, service = selected.service, operation = selected.operation,
        arguments = request.arguments, idempotency_key = request.idempotency_key}, "30s", true)
    if not called then return fail(tostring(call_error)) end
    local result, result_error = outbound.result(called)
    if result_error then return fail(result_error) end
    local answer = M.reply(result)
    if not answer then return fail("remote tool returned an invalid reply") end
    if answer.ok and output then
        local mismatch = schemas.validate(output, answer.value)
        if mismatch then return fail("invalid remote tool reply: " .. mismatch) end
    end
    return answer
end
function M.tests(request: Object): Reply
    local node = assert(bounds.id(request.node))
    local sent: Object = {}
    for key, value in pairs(request) do if key ~= "node" then sent[key] = value end end
    local reply, err = protocol.call(node, "application.tests", sent, "30s", true)
    if not reply then return fail(tostring(err)) end
    if not reply.ok then return fail(reply.error or "remote tests failed") end
    local answer = M.reply(reply.value and reply.value.reply)
    if not answer then return fail("invalid remote tests reply") end
    return answer
end
return M
