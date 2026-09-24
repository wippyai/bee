-- MIT. Synchronous execution validation and dispatch for Bee Hive open telemetry operations.
-- Caller supervisor runs this in a bounded worker/coroutine, authenticates peer/principal, and owns routes.
local canonical = require("canonical")
local json = require("json")
local funcs = require("funcs")
local types = require("types")
local catalog = require("catalog")
local bounds = require("bounds")

local M = {}

-- Exact reviewed open operations: node telemetry and the node's workspace catalog.
-- Generic exposing metadata must not make arbitrary funcs callable.
local ALLOWED_OPERATIONS: {[string]: boolean} = {
    ["bee.hive.telemetry:presence"] = true,
    ["bee.hive.telemetry:stats"] = true,
    ["bee.hive.telemetry:catalog_list"] = true,
    ["bee.hive.host:workspaces"] = true,
}

local function operation_namespace(operation_ref: string): string?
    return operation_ref:match("^([^:]+):[^:]+$")
end

-- Pure result validator: validates output against advertised schema and maximum bytes.
function M.validate_output(output_schema: {[string]: unknown}, max_output_bytes: integer, output: unknown): (boolean, string?)
    if type(output) ~= "table" then
        return false, "output must be an object"
    end
    local schema_bytes, schema_err = canonical.encode(output_schema)
    if not schema_bytes then
        return false, "output schema encoding failed: " .. tostring(schema_err)
    end
    local valid, validation = json.validate(schema_bytes, output)
    if not valid then
        return false, "output does not satisfy schema: " .. tostring(validation)
    end
    local encoded, enc_err = canonical.encode(output)
    if not encoded then
        return false, "output encoding failed: " .. tostring(enc_err)
    end
    if #encoded > max_output_bytes then
        return false, "output exceeds maximum allowed bytes"
    end
    return true, nil
end

-- Synchronous validation and dispatch for open telemetry requests.
function M.dispatch(request: unknown): types.Reply
    -- 1. Always re-decode request
    local req, decode_err = types.decode_request(request)
    if not req then
        local object = bounds.object(request)
        local raw_id = object and bounds.id(object.request_id) or "unknown"
        return types.reply_error(raw_id, types.fault("INVALID_ARGUMENT", "invalid request envelope"))
    end

    local request_id = req.request_id

    -- 2. Require resource_ref absent (node telemetry only)
    if req.owner_ref.resource_ref ~= nil then
        return types.reply_error(request_id, types.fault("INVALID_ARGUMENT", "node telemetry only: resource_ref must be absent"))
    end

    -- 3. Require owner_ref.service_id == namespace of operation_ref
    local expected_ns = operation_namespace(req.operation_ref)
    if not expected_ns or req.owner_ref.service_id ~= expected_ns then
        return types.reply_error(request_id, types.fault("INVALID_ARGUMENT", "owner service does not match operation namespace"))
    end

    -- 4. Exact three reviewed telemetry operations only in initial executable allowlist
    if not ALLOWED_OPERATIONS[req.operation_ref] then
        return types.reply_error(request_id, types.fault("DENIED", "operation not permitted"))
    end

    -- 5. Resolve canonical operation with catalog.resolve
    local op, resolve_err = catalog.resolve(req.operation_ref)
    if not op then
        return types.reply_error(request_id, types.fault("DENIED", "operation unavailable"))
    end

    -- 6. Require mode=open
    if op.mode ~= "open" then
        return types.reply_error(request_id, types.fault("DENIED", "operation mode is not open"))
    end

    -- 7. Check operation_revision
    if op.revision ~= req.operation_revision then
        return types.reply_error(request_id, types.fault("CONFLICT", "operation revision mismatch"))
    end

    -- 8. Revalidate input schema+limits using catalog.resolve_call and a tiny snapshot of the resolved descriptor
    local tiny_snapshot: catalog.Snapshot = {
        generation = 1,
        operations = {[op.operation_ref] = op},
        interfaces = {},
        diagnostics = {},
    }
    local resolved, resolve_call_err = catalog.resolve_call(tiny_snapshot, req.operation_ref, req.input)
    if not resolved then
        return types.reply_error(request_id, types.fault("INVALID_ARGUMENT", "input validation failed"))
    end

    -- 9. Check input_digest
    if resolved.input_digest ~= req.input_digest then
        return types.reply_error(request_id, types.fault("INVALID_ARGUMENT", "input digest mismatch"))
    end

    -- 10. Re-resolve immediately before funcs.call, comparing measured and revision to validated descriptor
    local fresh_op, fresh_err = catalog.resolve(req.operation_ref)
    if not fresh_op or fresh_op.revision ~= op.revision or fresh_op.measured ~= op.measured or fresh_op.mode ~= "open" then
        return types.reply_error(request_id, types.fault("INVALID_STATE", "operation definition modified"))
    end

    -- 11. Invoke funcs.call with normalized input
    local raw_output, call_err = funcs.call(op.operation_ref, resolved.input)
    if call_err then
        return types.reply_error(request_id, types.fault("INTERNAL", "operation execution failed"))
    end

    -- 12. Validate returned output against advertised output schema using json.validate and max_output_bytes
    local valid_out, out_err = M.validate_output(op.output_schema, op.limits.max_output_bytes, raw_output)
    if not valid_out then
        return types.reply_error(request_id, types.fault("INTERNAL", "operation output validation failed"))
    end

    -- 13. types.reply_ok validates the reply bound
    local reply = types.reply_ok(request_id, raw_output)
    local validated_reply, reply_err = types.decode_reply(reply)
    if not validated_reply then
        return types.reply_error(request_id, types.fault("INTERNAL", "reply bounds validation failed"))
    end

    return validated_reply
end

return M
