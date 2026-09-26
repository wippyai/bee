-- MIT. Catalog-declared policy operations through the existing admitted Hive route.
-- No metadata can extend this executable ceiling or select a destination actor.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local system = require("system")
local time = require("time")
local types = require("types")
local bounds = require("bounds")
local catalog = require("catalog")
local principals = require("principals")
local canonical = require("canonical")
local dispatch = require("dispatch")
local logger = require("logger")
local M = {}
-- Catalog metadata chooses the typed policy operation; it never grants it.
-- The destination still applies host exposure, principal mapping, mapped caller
-- policy and owner/service identity below.  This keeps the mesh generic for
-- new source-owned sync adapters without creating another transport allowlist.
local function service_of(operation_ref: string): string?
    return operation_ref:match("^([^:]+):[^:]+$")
end
function M.admits(operation_ref: string): boolean
    if not service_of(operation_ref) then return false end
    local operation = catalog.resolve(operation_ref)
    return operation ~= nil and operation.mode == "policy"
end
local function denied(id: string, code: string, message: string): types.Reply
    return types.reply_error(id, types.fault(code, message))
end
function M.handle(value: unknown): types.Reply
    local request, err = types.decode_request(value)
    if not request then return denied("", "INVALID_ARGUMENT", err or "invalid request") end
    local id = request.request_id
    local service = service_of(request.operation_ref)
    if not service then return denied(id, "INVALID_ARGUMENT", "operation reference has no service namespace") end
    local native, native_error = system.node.id()
    if native_error or native ~= request.owner_ref.node_id then return denied(id, "DENIED", "owner is not this node") end
    if request.owner_ref.service_id ~= service or request.owner_ref.resource_ref ~= nil then return denied(id, "INVALID_ARGUMENT", "feed owner service does not match") end
    if request.principal_ref.issuer ~= request.caller_node_id then return denied(id, "DENIED", "principal issuer does not match the verified peer") end
    if not catalog.admits("policy", request.operation_ref) then return denied(id, "DENIED", "host does not expose this operation") end
    local deadline = time.parse("2006-01-02T15:04:05.000Z07:00", request.deadline)
    if not deadline or not deadline:after(time.now()) then return denied(id, "DEADLINE_EXCEEDED", "request deadline passed") end
    local entry = registry.get(principals.ENTRY)
    if not entry or type(entry.data) ~= "table" then return denied(id, "UNAVAILABLE", "principal mappings unavailable") end
    local mappings, mapping_error = principals.decode(entry.data)
    if not mappings then return denied(id, "UNAVAILABLE", mapping_error or "invalid principal mappings") end
    local mapping = principals.resolve(mappings, request.principal_ref)
    if not mapping then return denied(id, "DENIED", "principal has no destination mapping") end
    local operation, operation_error = catalog.resolve(request.operation_ref)
    if not operation or operation.mode ~= "policy" or operation.revision ~= request.operation_revision then
        return denied(id, "CONFLICT", operation_error or "operation changed")
    end
    local tiny: catalog.Snapshot = {generation = 0, operations = {[operation.operation_ref] = operation}, interfaces = {}, diagnostics = {}}
    local resolved, resolve_error = catalog.resolve_call(tiny, request.operation_ref, request.input)
    if not resolved or resolved.input_digest ~= request.input_digest then return denied(id, "INVALID_ARGUMENT", resolve_error or "input digest mismatch") end
    local policies: {security.Policy} = {}
    for index, reference in ipairs(mapping.policies) do
        local policy, policy_error = security.policy(reference)
        if not policy or policy_error then return denied(id, "UNAVAILABLE", "mapped policy unavailable") end
        policies[index] = policy
    end
    local caller = funcs.new():with_actor(security.new_actor(mapping.actor_id)):with_scope(security.new_scope(policies))
    local verdict, verdict_error = caller:call("bee.hive.supervisor:invoke_check", {operation_ref = request.operation_ref})
    if verdict_error then logger:named("bee.hive.policy"):error("Policy invocation check failed", {cause = tostring(verdict_error):sub(1, 1024)}) end
    if verdict_error or type(verdict) ~= "table" or verdict.allowed ~= true then return denied(id, "DENIED", "principal may not invoke the operation") end
    local current = catalog.resolve(request.operation_ref)
    if not current or current.measured ~= operation.measured then return denied(id, "CONFLICT", "operation definition changed") end
    local output, output_error = caller:call(request.operation_ref, resolved.input)
    if output_error then return denied(id, "UNAVAILABLE", "owner outcome is unknown; read its durable state before retrying") end
    if type(output) ~= "table" or type(output.ok) ~= "boolean" then return denied(id, "INTERNAL", "owner reply is malformed") end
    local valid = dispatch.validate_output(operation.output_schema, operation.limits.max_output_bytes, output)
    if not valid then return denied(id, "UNAVAILABLE", "owner reply failed its contract; reconcile before retrying") end
    local encoded = canonical.encode(output)
    if not encoded or #encoded > types.MAX_OUTPUT_BYTES then return denied(id, "UNAVAILABLE", "owner reply exceeds transport capacity; reconcile before retrying") end
    -- Preserve the owner's domain receipt, including conflict details and replay.
    return types.reply_ok(id, output)
end
return M
