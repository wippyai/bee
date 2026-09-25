-- MIT. Thread-operation admission at the destination. After ingress
-- verified the caller node, its incarnation and the principal assertion,
-- a forwarded send or send_status runs as the actor the host maps that
-- principal to, under the scope the host selected for it, with the caller
-- node the ingress authenticated. The payload selects none of those: a
-- caller node it carries must match, and actor or scope fields refuse the
-- request. The destination thread owner then checks membership and
-- commits under its own identity rules; nothing here substitutes a
-- service actor or grants beyond the mapping's policies.
local funcs = require("funcs")
local security = require("security")
local time = require("time")
local types = require("types")
local bounds = require("bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local principals = require("principals")
local M = {}
-- The thread operations, their contract revision and the exact payload
-- each takes; the exposure mode a host ceiling must admit for them.
M.OPERATION_REVISION = "1"
M.EXPOSURE_MODE = "policy"
M.OWNER_SERVICE = "bee.threads"
M.OPERATIONS = {["bee.threads.service:send"] = true, ["bee.threads.service:send_status"] = true}
local fields_by_operation: {[string]: {string}} = {
    ["bee.threads.service:send"] = {"thread_id", "idempotency_key", "caller_node_id", "payload_digest", "message", "context"},
    ["bee.threads.service:send_status"] = {"thread_id", "idempotency_key", "caller_node_id"},
}
M.FIELDS = fields_by_operation
M.RESERVED = {"actor", "actor_id", "principal", "principal_id", "principal_ref", "scope", "policies", "owner_id"}
M.INVOKE_CHECK = "bee.hive_host.supervisor:invoke_check"
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
type Object = {[string]: unknown}
type Admission = {actor_id: string, policies: {string}, operation_ref: string, input: Object, caller_node_id: string, principal: types.PrincipalRef}
type ServiceReply = {ok: boolean, error: {code: string, message: string}?, value: unknown, replayed: boolean?}
-- admit: the common operation checks a forwarded request faces on every
-- path (host exposure ceiling, owner service, revision, exact payload
-- fields, digest, deadline) and then the principal mapping; a mapped
-- actor with a thread membership bypasses none of them.
function M.admit(local_node: string, request: types.Request, mappings: principals.Mappings, now: time.Time): (Admission?, types.Fault?)
    if not M.OPERATIONS[request.operation_ref] then return nil, types.fault("UNSUPPORTED_CAPABILITY", "operation " .. request.operation_ref .. " is not a thread operation") end
    if not security.can(catalog.exposure_action(M.EXPOSURE_MODE), request.operation_ref) then return nil, types.fault("DENIED", "the host does not expose " .. request.operation_ref .. " to forwarded principals") end
    if request.owner_ref.node_id ~= local_node then return nil, types.fault("DENIED", "request owner is not on this node") end
    if request.owner_ref.service_id ~= M.OWNER_SERVICE then return nil, types.fault("INVALID_ARGUMENT", "owner must be the " .. M.OWNER_SERVICE .. " service") end
    if request.operation_revision ~= M.OPERATION_REVISION then return nil, types.fault("CONFLICT", "operation revision mismatch") end
    local fields = fields_by_operation[request.operation_ref]
    if not fields then return nil, types.fault("UNSUPPORTED_CAPABILITY", "operation " .. request.operation_ref .. " has no payload contract") end
    local unknown_field = bounds.fields(request.input, fields)
    if unknown_field then return nil, types.fault("INVALID_ARGUMENT", "input: " .. unknown_field) end
    -- The owner reference binds the destination thread: the resource it
    -- names is the thread the payload addresses, before anything runs.
    local thread_id = bounds.id(request.input.thread_id)
    if not thread_id then return nil, types.fault("INVALID_ARGUMENT", "input.thread_id is not an identifier") end
    if request.owner_ref.resource_ref ~= thread_id then return nil, types.fault("INVALID_ARGUMENT", "owner resource_ref must name the thread the payload addresses") end
    local digest, digest_error = types.digest(request.input)
    if not digest or digest ~= request.input_digest then return nil, types.fault("INVALID_ARGUMENT", "input digest mismatch: " .. tostring(digest_error)) end
    local deadline, deadline_error = time.parse(FORMAT, request.deadline)
    if deadline_error or not deadline then return nil, types.fault("INVALID_ARGUMENT", "invalid deadline") end
    if not deadline:after(now) then return nil, types.fault("DEADLINE_EXCEEDED", "request deadline has passed") end
    if request.principal_ref.issuer ~= request.caller_node_id then return nil, types.fault("DENIED", "principal issuer is not the authenticated caller node") end
    local mapping = principals.resolve(mappings, request.principal_ref)
    if not mapping then return nil, types.fault("DENIED", "principal is not mapped on this node") end
    local input: Object = {}
    for name, item in pairs(request.input) do input[name] = item end
    for _, reserved in ipairs(M.RESERVED) do
        if input[reserved] ~= nil then return nil, types.fault("INVALID_ARGUMENT", "the payload may not carry " .. reserved) end
    end
    if input.caller_node_id ~= nil and input.caller_node_id ~= request.caller_node_id then
        return nil, types.fault("INVALID_ARGUMENT", "caller_node_id in the payload does not match the authenticated caller node")
    end
    input.caller_node_id = request.caller_node_id
    return {actor_id = mapping.actor_id, policies = mapping.policies, operation_ref = request.operation_ref, input = input, caller_node_id = request.caller_node_id, principal = request.principal_ref}, nil
end
-- execute: the operation under the mapped actor and the host-selected
-- scope; the thread owner's reply comes back as the hive reply.
function M.execute(request_id: string, admission: Admission): types.Reply
    local policies: {security.Policy} = {}
    for index, name in ipairs(admission.policies) do
        local policy, err = security.policy(name)
        if err or not policy then return types.reply_error(request_id, types.fault("UNAVAILABLE", "host scope policy " .. name .. " is unavailable")) end
        policies[index] = policy
    end
    local principal = funcs.new():with_actor(security.new_actor(admission.actor_id)):with_scope(security.new_scope(policies))
    -- Invocation is the principal's own authority: the check runs under the
    -- mapped actor and scope, where no worker grant reaches.
    local verdict, check_error = principal:call(M.INVOKE_CHECK, {operation_ref = admission.operation_ref})
    if check_error or type(verdict) ~= "table" or (verdict :: {[string]: unknown}).allowed ~= true then
        return types.reply_error(request_id, types.fault("DENIED", "principal may not invoke " .. admission.operation_ref))
    end
    local raw, call_error = principal:call(admission.operation_ref, admission.input)
    if call_error then return types.reply_error(request_id, types.fault("DENIED", "thread operation refused: " .. tostring(call_error))) end
    if type(raw) ~= "table" then return types.reply_error(request_id, types.fault("INTERNAL", "thread owner answered without a reply")) end
    local reply = raw :: ServiceReply
    if reply.ok then
        local encoded = canonical.encode(reply.value)
        if encoded and #encoded > types.MAX_OUTPUT_BYTES then
            return types.reply_error(request_id, types.uncertain("reply exceeds the output bound; the operation may have committed",
                {operation_ref = admission.operation_ref, idempotency_key = tostring(admission.input.idempotency_key)}))
        end
        return types.reply_ok(request_id, reply.value)
    end
    local fault = reply.error or {code = "INTERNAL", message = "thread operation failed"}
    return types.reply_error(request_id, types.fault(fault.code, fault.message))
end
-- mappings: the host's table, read from the registry when asked.
function M.mappings(entry: unknown): (principals.Mappings?, string?)
    local object = bounds.object(entry)
    if not object then return nil, "principal mappings entry is missing" end
    local meta = bounds.object(object.meta) or {}
    if meta.type ~= principals.ENTRY_TYPE then return nil, "principal mappings entry is not a " .. principals.ENTRY_TYPE end
    return principals.decode(object.data)
end
return M
