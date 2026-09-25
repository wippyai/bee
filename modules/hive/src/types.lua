-- MIT. Envelopes of the Hive protocol: what a caller hands its supervisor,
-- what supervisors exchange, and what comes back. Every value crossing a
-- process boundary is decoded here before anything trusts it.
local hash = require("hash")
local canonical = require("canonical")
local bounds = require("bounds")
local M = {}
M.REVISION = "bee.hive@1"
M.TOPIC_REQUEST = "bee.hive.request"
M.TOPIC_REPLY = "bee.hive.reply"
M.TOPIC_HELLO = "bee.hive.hello"
M.TOPIC_EPOCH = "bee.hive.epoch"
M.SUPERVISOR_NAME = "bee.hive_host.supervisor"
M.SUPERVISOR_HOST = "bee.hive_host:supervisor_host"
M.ASSERTION_METHOD = "node_supervisor"
M.MAX_INPUT_BYTES = 65536
M.MAX_OUTPUT_BYTES = 262144
M.MODES = {"open", "approval", "policy"}
M.CODES = {"INVALID_ARGUMENT", "UNSUPPORTED_SCHEMA", "UNSUPPORTED_CAPABILITY", "DENIED", "NOT_FOUND", "CONFLICT",
    "LIMIT_EXCEEDED", "INVALID_STATE", "DESKTOP_CONTROLLED", "BUSY", "UNAVAILABLE", "DEADLINE_EXCEEDED", "UNCERTAIN", "INTERNAL"}
type Mode = "open" | "approval" | "policy"
-- identity: on an UNCERTAIN fault, the stable operation and idempotency
-- identity a caller uses for status or an identical replay; prose never
-- decides retry behavior.
type FaultIdentity = {operation_ref: string, idempotency_key: string}
type Fault = {code: string, message: string, retryable: boolean, identity: FaultIdentity?}
type OwnerRef = {node_id: string, service_id: string, resource_ref: string?}
type Target = {operation_ref: string?, interface_ref: string?}
-- What a local caller hands its own supervisor. It names no principal and no
-- node; the supervisor derives both.
type Call = {
    protocol_revision: string,
    request_id: string,
    idempotency_key: string,
    owner_ref: OwnerRef,
    target: Target,
    input: {[string]: unknown},
    deadline: string?,
}
type PrincipalRef = {issuer: string, subject_id: string}
type PrincipalAssertion = {method: string, audience: string, issued_at: string, expires_at: string}
-- What one supervisor forwards to another: supervisor-derived identity and
-- the effective input after interfaces were applied.
type Request = {
    protocol_revision: string,
    request_id: string,
    idempotency_key: string,
    caller_node_id: string,
    caller_incarnation: string,
    owner_ref: OwnerRef,
    operation_ref: string,
    operation_revision: string,
    input: {[string]: unknown},
    input_digest: string,
    principal_ref: PrincipalRef,
    principal_assertion: PrincipalAssertion,
    delegation_refs: {string},
    deadline: string,
    causation_ref: string?,
    return_ref: string?,
}
type GrantRef = {grant_id: string, issuer_owner_ref: OwnerRef, authorization_epoch: integer, expires_at: string}
type Reply = {
    protocol_revision: string,
    request_id: string,
    ok: boolean,
    error: Fault?,
    value: unknown,
    grants: {GrantRef},
}
type Grant = {
    grant_id: string,
    issuer_owner_ref: OwnerRef,
    subject_ref: PrincipalRef,
    audience: string,
    allowed_operations: {string},
    resource_scope: {[string]: unknown},
    limits: {[string]: integer},
    owner_incarnation: string,
    authorization_epoch: integer,
    expires_at: string,
    delegation_policy: "none",
}
type Transport = "tty_mount" | "process_messages"
type Session = {
    communication_session_id: string,
    transport: Transport,
    grant_refs: {string},
    endpoint_refs: {string},
    protocol_revision: string,
    directions: {string},
    limits: {[string]: integer},
    expires_at: string,
    mount_ref: string?,
}
type Frame = {communication_session_id: string, sequence: integer, payload: unknown}
type Hello = {protocol_revision: string, supervisor_incarnation: string, challenge: string, response: string?}
function M.fault(code: string, message: string): Fault
    return {code = code, message = message, retryable = code == "BUSY" or code == "UNAVAILABLE"}
end
-- uncertain: the outcome is unknown after dispatch may have committed; the
-- identity names what to ask about or replay identically.
function M.uncertain(message: string, identity: FaultIdentity): Fault
    return {code = "UNCERTAIN", message = message, retryable = false, identity = {operation_ref = identity.operation_ref, idempotency_key = identity.idempotency_key}}
end
function M.decode_fault(value: unknown): (Fault?, string?)
    local fault = bounds.object(value)
    if not fault then return nil, "fault must be an object" end
    local unknown_field = bounds.fields(fault, {"code", "message", "retryable", "identity"})
    if unknown_field then return nil, unknown_field end
    local code = bounds.id(fault.code)
    if not code then return nil, "fault code is not an identifier" end
    local identity: FaultIdentity? = nil
    if fault.identity ~= nil then
        local declared = bounds.object(fault.identity)
        if not declared then return nil, "fault identity must be an object" end
        local unknown_identity = bounds.fields(declared, {"operation_ref", "idempotency_key"})
        if unknown_identity then return nil, "fault identity: " .. unknown_identity end
        local operation_ref, idempotency_key = bounds.id(declared.operation_ref), bounds.id(declared.idempotency_key)
        if not operation_ref or not idempotency_key then return nil, "fault identity needs operation_ref and idempotency_key" end
        if code ~= "UNCERTAIN" then return nil, "only an UNCERTAIN fault carries an identity" end
        identity = {operation_ref = operation_ref, idempotency_key = idempotency_key}
    end
    local known = false
    for _, candidate in ipairs(M.CODES) do
        if candidate == code then known = true end
    end
    if not known then return nil, "fault code is not a Hive error code" end
    local message: unknown, retryable: unknown = fault.message, fault.retryable
    if type(message) ~= "string" or #message > 4096 then return nil, "fault message is not bounded text" end
    if type(retryable) ~= "boolean" then return nil, "fault retryable must be a boolean" end
    return {code = code, message = message, retryable = retryable, identity = identity}, nil
end
function M.decode_owner(value: unknown): (OwnerRef?, string?)
    local owner = bounds.object(value)
    if not owner then return nil, "owner_ref must be an object" end
    local unknown_field = bounds.fields(owner, {"node_id", "service_id", "resource_ref"})
    if unknown_field then return nil, unknown_field end
    local node_id, service_id = bounds.id(owner.node_id), bounds.id(owner.service_id)
    if not node_id then return nil, "owner node_id is not an identifier" end
    if not service_id then return nil, "owner service_id is not an identifier" end
    local resource, valid = bounds.optional_id(owner, "resource_ref")
    if not valid then return nil, "owner resource_ref is not an identifier" end
    return {node_id = node_id, service_id = service_id, resource_ref = resource}, nil
end
-- Inputs are bounded by their canonical size, the same bytes the digest covers.
function M.decode_input(value: unknown): ({[string]: unknown}?, string?)
    local input = bounds.object(value)
    if not input then return nil, "input must be an object" end
    local encoded, encode_error = canonical.encode(input)
    if not encoded then return nil, "input is not encodable: " .. tostring(encode_error) end
    if #encoded > M.MAX_INPUT_BYTES then return nil, "input exceeds " .. tostring(M.MAX_INPUT_BYTES) .. " bytes" end
    return input, nil
end
function M.digest(input: {[string]: unknown}): (string?, string?)
    local encoded, encode_error = canonical.encode(input)
    if not encoded then return nil, encode_error end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, "digest input" end
    return digest, nil
end
local function decode_target(value: unknown): (Target?, string?)
    local target = bounds.object(value)
    if not target then return nil, "target must be an object" end
    local unknown_field = bounds.fields(target, {"operation_ref", "interface_ref"})
    if unknown_field then return nil, unknown_field end
    local result: Target = {}
    local operation, operation_valid = bounds.optional_id(target, "operation_ref")
    if not operation_valid then return nil, "operation_ref is not an identifier" end
    result.operation_ref = operation
    local facade, interface_valid = bounds.optional_id(target, "interface_ref")
    if not interface_valid then return nil, "interface_ref is not an identifier" end
    result.interface_ref = facade
    local has_operation = operation ~= nil
    local has_interface = facade ~= nil
    if has_operation == has_interface then return nil, "target names exactly one of operation_ref or interface_ref" end
    return result, nil
end
function M.decode_call(value: unknown): (Call?, string?)
    local call = bounds.object(value)
    if not call then return nil, "call must be an object" end
    local unknown_field = bounds.fields(call, {"protocol_revision", "request_id", "idempotency_key", "owner_ref", "target", "input", "deadline"})
    if unknown_field then return nil, unknown_field end
    if call.protocol_revision ~= M.REVISION then return nil, "protocol_revision is not " .. M.REVISION end
    local request_id, key = bounds.id(call.request_id), bounds.id(call.idempotency_key)
    if not request_id then return nil, "request_id is not an identifier" end
    if not key then return nil, "idempotency_key is not an identifier" end
    local owner, owner_error = M.decode_owner(call.owner_ref)
    if not owner then return nil, owner_error end
    local target, target_error = decode_target(call.target)
    if not target then return nil, target_error end
    local input, input_error = M.decode_input(call.input)
    if not input then return nil, input_error end
    local result: Call = {protocol_revision = M.REVISION, request_id = request_id, idempotency_key = key, owner_ref = owner, target = target, input = input}
    if call.deadline ~= nil then
        local deadline = bounds.timestamp(call.deadline)
        if not deadline then return nil, "deadline is not a canonical UTC timestamp" end
        result.deadline = deadline
    end
    return result, nil
end
function M.decode_principal(value: unknown): (PrincipalRef?, string?)
    local principal = bounds.object(value)
    if not principal then return nil, "principal_ref must be an object" end
    local unknown_field = bounds.fields(principal, {"issuer", "subject_id"})
    if unknown_field then return nil, unknown_field end
    local issuer, subject = bounds.id(principal.issuer), bounds.id(principal.subject_id)
    if not issuer then return nil, "principal issuer is not an identifier" end
    if not subject then return nil, "principal subject_id is not an identifier" end
    return {issuer = issuer, subject_id = subject}, nil
end
local function decode_assertion(value: unknown): (PrincipalAssertion?, string?)
    local assertion = bounds.object(value)
    if not assertion then return nil, "principal_assertion must be an object" end
    local unknown_field = bounds.fields(assertion, {"method", "audience", "issued_at", "expires_at"})
    if unknown_field then return nil, unknown_field end
    local method, audience = bounds.id(assertion.method), bounds.id(assertion.audience)
    local issued, expires = bounds.timestamp(assertion.issued_at), bounds.timestamp(assertion.expires_at)
    if not method or method ~= M.ASSERTION_METHOD then return nil, "assertion method must be " .. M.ASSERTION_METHOD end
    if not audience then return nil, "assertion audience is not an identifier" end
    if not issued or not expires then return nil, "assertion times are not canonical UTC timestamps" end
    if expires <= issued then return nil, "assertion expires before it is issued" end
    return {method = method, audience = audience, issued_at = issued, expires_at = expires}, nil
end
function M.decode_request(value: unknown): (Request?, string?)
    local request = bounds.object(value)
    if not request then return nil, "request must be an object" end
    local unknown_field = bounds.fields(request, {"protocol_revision", "request_id", "idempotency_key", "caller_node_id", "caller_incarnation",
        "owner_ref", "operation_ref", "operation_revision", "input", "input_digest", "principal_ref", "principal_assertion",
        "delegation_refs", "deadline", "causation_ref", "return_ref"})
    if unknown_field then return nil, unknown_field end
    if request.protocol_revision ~= M.REVISION then return nil, "protocol_revision is not " .. M.REVISION end
    local request_id, key = bounds.id(request.request_id), bounds.id(request.idempotency_key)
    local caller_node_id, caller_incarnation = bounds.id(request.caller_node_id), bounds.id(request.caller_incarnation)
    local operation_ref, operation_revision = bounds.id(request.operation_ref), bounds.id(request.operation_revision)
    local input_digest = bounds.id(request.input_digest)
    if not request_id then return nil, "request_id is not an identifier" end
    if not key then return nil, "idempotency_key is not an identifier" end
    if not caller_node_id then return nil, "caller_node_id is not an identifier" end
    if not caller_incarnation then return nil, "caller_incarnation is not an identifier" end
    if not operation_ref then return nil, "operation_ref is not an identifier" end
    if not operation_revision then return nil, "operation_revision is not an identifier" end
    if not input_digest then return nil, "input_digest is not an identifier" end
    local owner, owner_error = M.decode_owner(request.owner_ref)
    if not owner then return nil, owner_error end
    local input, input_error = M.decode_input(request.input)
    if not input then return nil, input_error end
    local digest, digest_error = M.digest(input)
    if not digest then return nil, digest_error end
    if digest ~= input_digest then return nil, "input_digest does not match the input" end
    local principal, principal_error = M.decode_principal(request.principal_ref)
    if not principal then return nil, principal_error end
    local assertion, assertion_error = decode_assertion(request.principal_assertion)
    if not assertion then return nil, assertion_error end
    local delegations, delegations_error = bounds.ids(request.delegation_refs)
    if not delegations then return nil, "delegation_refs: " .. tostring(delegations_error) end
    if #delegations > 0 then return nil, "delegation_refs must be empty until delegation exists" end
    if assertion.audience ~= owner.node_id then return nil, "assertion audience must be the owner node" end
    local deadline = bounds.timestamp(request.deadline)
    if not deadline then return nil, "a forwarded request needs a canonical UTC deadline" end
    if assertion.expires_at > deadline then return nil, "assertion validity cannot outlive the deadline" end
    local result: Request = {protocol_revision = M.REVISION, request_id = request_id, idempotency_key = key,
        caller_node_id = caller_node_id, caller_incarnation = caller_incarnation, owner_ref = owner,
        operation_ref = operation_ref, operation_revision = operation_revision, input = input, input_digest = digest,
        principal_ref = principal, principal_assertion = assertion, delegation_refs = delegations, deadline = deadline}
    for _, name in ipairs({"causation_ref", "return_ref"}) do
        local item, valid = bounds.optional_id(request, name)
        if not valid then return nil, name .. " is not an identifier" end
        if name == "causation_ref" then result.causation_ref = item else result.return_ref = item end
    end
    return result, nil
end
local function decode_grant_ref(value: unknown): (GrantRef?, string?)
    local ref = bounds.object(value)
    if not ref then return nil, "grant reference must be an object" end
    local unknown_field = bounds.fields(ref, {"grant_id", "issuer_owner_ref", "authorization_epoch", "expires_at"})
    if unknown_field then return nil, unknown_field end
    local grant_id = bounds.id(ref.grant_id)
    if not grant_id then return nil, "grant_id is not an identifier" end
    local issuer, issuer_error = M.decode_owner(ref.issuer_owner_ref)
    if not issuer then return nil, issuer_error end
    local epoch = bounds.integer(ref.authorization_epoch)
    local expires = bounds.timestamp(ref.expires_at)
    if not epoch or epoch < 1 then return nil, "authorization_epoch must be a positive integer" end
    if not expires then return nil, "expires_at is not a canonical UTC timestamp" end
    return {grant_id = grant_id, issuer_owner_ref = issuer, authorization_epoch = epoch, expires_at = expires}, nil
end
function M.decode_reply(value: unknown): (Reply?, string?)
    local reply = bounds.object(value)
    if not reply then return nil, "reply must be an object" end
    local unknown_field = bounds.fields(reply, {"protocol_revision", "request_id", "ok", "error", "value", "grants"})
    if unknown_field then return nil, unknown_field end
    if reply.protocol_revision ~= M.REVISION then return nil, "protocol_revision is not " .. M.REVISION end
    local request_id = bounds.id(reply.request_id)
    if not request_id then return nil, "request_id is not an identifier" end
    local ok: unknown = reply.ok
    if type(ok) ~= "boolean" then return nil, "ok must be a boolean" end
    local has_error = reply.error ~= nil
    if ok == has_error then return nil, "a reply carries exactly one of value or error" end
    if not ok and reply.value ~= nil then return nil, "a failed reply carries no value" end
    local result: Reply = {protocol_revision = M.REVISION, request_id = request_id, ok = ok, grants = {}}
    if reply.error ~= nil then
        local fault, fault_error = M.decode_fault(reply.error)
        if not fault then return nil, fault_error end
        result.error = fault
    end
    if ok then
        local encoded, encode_error = canonical.encode(reply.value)
        if not encoded then return nil, "value is not encodable: " .. tostring(encode_error) end
        if #encoded > M.MAX_OUTPUT_BYTES then return nil, "value exceeds " .. tostring(M.MAX_OUTPUT_BYTES) .. " bytes" end
        result.value = reply.value
    end
    if reply.grants ~= nil then
        local list: unknown = reply.grants
        if type(list) ~= "table" then return nil, "grants must be a list" end
        local count = 0
        for key in pairs(list) do
            if type(key) ~= "number" then return nil, "grants must be a list" end
            count = count + 1
        end
        if count > bounds.MAX_LIST_ITEMS then return nil, "grants exceed " .. tostring(bounds.MAX_LIST_ITEMS) .. " items" end
        for index = 1, count do
            local grant, grant_error = decode_grant_ref(list[index])
            if not grant then return nil, "grants[" .. tostring(index) .. "]: " .. tostring(grant_error) end
            result.grants[index] = grant
        end
    end
    return result, nil
end
function M.reply_ok(request_id: string, value: unknown): Reply
    local grants: {GrantRef} = {}
    local reply: Reply = {protocol_revision = M.REVISION, request_id = request_id, ok = true, grants = grants}
    reply.value = value
    return reply
end
function M.reply_error(request_id: string, fault: Fault): Reply
    local grants: {GrantRef} = {}
    local reply: Reply = {protocol_revision = M.REVISION, request_id = request_id, ok = false, grants = grants}
    reply.error = fault
    return reply
end
function M.decode_frame(value: unknown): (Frame?, string?)
    local frame = bounds.object(value)
    if not frame then return nil, "frame must be an object" end
    local unknown_field = bounds.fields(frame, {"communication_session_id", "sequence", "payload"})
    if unknown_field then return nil, unknown_field end
    local session = bounds.id(frame.communication_session_id)
    local sequence = bounds.integer(frame.sequence)
    if not session then return nil, "communication_session_id is not an identifier" end
    if not sequence or sequence < 1 then return nil, "sequence must be a positive integer" end
    if frame.payload == nil then return nil, "payload is required" end
    return {communication_session_id = session, sequence = sequence, payload = frame.payload}, nil
end
function M.decode_hello(value: unknown): (Hello?, string?)
    local hello = bounds.object(value)
    if not hello then return nil, "hello must be an object" end
    local unknown_field = bounds.fields(hello, {"protocol_revision", "supervisor_incarnation", "challenge", "response"})
    if unknown_field then return nil, unknown_field end
    if hello.protocol_revision ~= M.REVISION then return nil, "protocol_revision is not " .. M.REVISION end
    local incarnation, challenge = bounds.id(hello.supervisor_incarnation), bounds.id(hello.challenge)
    if not incarnation then return nil, "supervisor_incarnation is not an identifier" end
    if not challenge then return nil, "challenge is not an identifier" end
    local response, valid = bounds.optional_id(hello, "response")
    if not valid then return nil, "response is not an identifier" end
    return {protocol_revision = M.REVISION, supervisor_incarnation = incarnation, challenge = challenge, response = response}, nil
end
-- A PID is {node@host|uniq}; the host component names the process.host the
-- runtime placed the process on.
function M.pid_parts(pid: string): (string?, string?)
    local node, host = pid:match("^{([^@|}]*)@([^|}]+)|[^}]+}$")
    if not host then
        host = pid:match("^{([^|}]+)|[^}]+}$")
        if not host then return nil, nil end
        return "", host
    end
    return node, host
end
return M
