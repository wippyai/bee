-- MIT. Node-level immutable replica admission. The established supervisor
-- session authenticates the caller node; every request must name that same
-- node as source owner. This grants receipt into an inert cache only.
local funcs = require("funcs")
local security = require("security")
local system = require("system")
local types = require("types")
local bounds = require("bounds")
local catalog = require("catalog")
local version = require("version")
local dispatch = require("dispatch")
local canonical = require("canonical")

local M = {}
M.OPERATION = "bee.sync.binding:replica_receive"

local function denied(id: string, code: string, message: string): types.Reply
    return types.reply_error(id, types.fault(code, message))
end

local function source(input: {[string]: unknown}): string?
    if input.action == "begin" then
        local descriptor = version.decode(input.descriptor)
        return descriptor and descriptor.owner_id or nil
    end
    return bounds.id(input.source_owner)
end

function M.handle(value: unknown): types.Reply
    local request, request_error = types.decode_request(value)
    if not request then return denied("", "INVALID_ARGUMENT", request_error or "invalid request") end
    local id = request.request_id
    if request.operation_ref ~= M.OPERATION then return denied(id, "DENIED", "operation is not node replica receipt") end
    local node, node_error = system.node.id()
    if node_error or not node or request.owner_ref.node_id ~= node
        or request.owner_ref.service_id ~= "bee.sync.binding" or request.owner_ref.resource_ref ~= nil then
        return denied(id, "DENIED", "replica owner is not this node")
    end
    if request.principal_ref.issuer ~= request.caller_node_id then
        return denied(id, "DENIED", "replica principal does not match the established peer")
    end
    local subject_node = types.pid_parts(request.principal_ref.subject_id)
    if subject_node ~= request.caller_node_id then return denied(id, "DENIED", "replica principal is outside its node") end
    if not security.can("hive.expose.policy", M.OPERATION) then return denied(id, "DENIED", "host does not expose replica receipt") end
    local operation, operation_error = catalog.resolve(M.OPERATION)
    if not operation or operation.mode ~= "policy" or operation.revision ~= request.operation_revision then
        return denied(id, "CONFLICT", operation_error or "replica operation changed")
    end
    local tiny: catalog.Snapshot = {generation = 0, operations = {[M.OPERATION] = operation}, interfaces = {}, diagnostics = {}}
    local resolved, resolve_error = catalog.resolve_call(tiny, M.OPERATION, request.input)
    if not resolved or resolved.input_digest ~= request.input_digest then
        return denied(id, "INVALID_ARGUMENT", resolve_error or "replica input digest mismatch")
    end
    if source(resolved.input) ~= request.caller_node_id then
        return denied(id, "DENIED", "replica source owner does not match the authenticated peer")
    end
    local policy, policy_error = security.policy("bee:hive_replica_peer_policy")
    if not policy then return denied(id, "UNAVAILABLE", tostring(policy_error or "replica receipt policy unavailable")) end
    local caller = funcs.new():with_actor(security.new_actor("bee.hive.node." .. request.caller_node_id))
        :with_scope(security.new_scope({policy}))
    local output, output_error = caller:call(M.OPERATION, resolved.input)
    if output_error or type(output) ~= "table" or type(output.ok) ~= "boolean" then
        return denied(id, "UNAVAILABLE", "replica owner outcome is unknown; read durable status before retrying")
    end
    if not dispatch.validate_output(operation.output_schema, operation.limits.max_output_bytes, output) then
        return denied(id, "UNAVAILABLE", "replica owner reply failed its contract")
    end
    local encoded = canonical.encode(output)
    if not encoded or #encoded > types.MAX_OUTPUT_BYTES then return denied(id, "UNAVAILABLE", "replica owner reply exceeds transport capacity") end
    return types.reply_ok(id, output)
end

return M
