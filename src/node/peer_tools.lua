-- MIT
local protocol = require("protocol")
local bounds = require("bounds")
local outbound = require("outbound")
local schemas = require("schemas")
local declarations = require("declarations")
local M = {}
type Object = {[string]: unknown}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
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
    local answer = bounds.object(result)
    if not answer or type(answer.ok) ~= "boolean" then return fail("remote tool returned an invalid reply") end
    if answer.ok == true and output then
        local mismatch = schemas.validate(output, answer.value)
        if mismatch then return fail("invalid remote tool reply: " .. mismatch) end
    end
    return answer :: Reply
end
function M.tests(request: Object): Reply
    local node = assert(bounds.id(request.node))
    local sent: Object = {}
    for key, value in pairs(request) do if key ~= "node" then sent[key] = value end end
    local reply, err = protocol.call(node, "application.tests", sent, "30s", true)
    if not reply then return fail(tostring(err)) end
    if not reply.ok then return fail(reply.error or "remote tests failed") end
    local answer = reply.value and bounds.object(reply.value.reply) or nil
    if not answer or type(answer.ok) ~= "boolean" then return fail("invalid remote tests reply") end
    return answer :: Reply
end
return M
