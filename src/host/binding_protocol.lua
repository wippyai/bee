-- MIT. Strict private broker-to-host application/thread binding envelopes.
--
-- The host authenticates the sender and owns the store.  This module only
-- decodes the wire values; it carries no process, database, or permission
-- authority across the boundary.
type Operation = "prepare" | "activate" | "refresh_join" | "begin_revoke" | "refresh_cleanup" | "finish_revoke"
type State = "pending" | "active" | "revoked"
type Object = {[string]: unknown}
type PrepareValue = {
    instance_id: string,
    thread_id: string,
    definition_id: string,
    actor_id: string,
    role: "participant",
    idempotency_key: string,
    definition_revision: string,
    initiating_owner_id: string,
    gateway_binding_id: string,
    gateway_approval_id: string,
    gateway_proposal_digest: string,
    access: "observe_post",
    join_expected_revision: integer,
}
type ActivateValue = {instance_id: string, expected_revision: integer, expected_state: "pending", membership_revision: integer}
type RefreshJoinValue = {instance_id: string, expected_revision: integer, expected_state: "pending", join_expected_revision: integer}
type BeginRevokeValue = {instance_id: string, expected_revision: integer, expected_state: "pending" | "active", cleanup_expected_revision: integer}
type RefreshCleanupValue = {instance_id: string, expected_revision: integer, expected_state: "revoked", cleanup_expected_revision: integer}
type FinishRevokeValue = {instance_id: string, expected_revision: integer, expected_state: "revoked"}
type Value = PrepareValue | ActivateValue | RefreshJoinValue | BeginRevokeValue | RefreshCleanupValue | FinishRevokeValue
type Request = {version: 1, workspace_id: string, request_id: string, op: Operation, value: Value}
type Binding = {
    instance_id: string,
    thread_id: string,
    definition_id: string,
    actor_id: string,
    role: "participant",
    binding_revision: integer,
    state: State,
    idempotency_key: string,
    definition_revision: string,
    initiating_owner_id: string,
    gateway_binding_id: string,
    gateway_approval_id: string,
    gateway_proposal_digest: string,
    access: "observe_post",
    join_expected_revision: integer,
    membership_revision: integer?,
    cleanup_pending: 0 | 1,
    cleanup_expected_revision: integer?,
}
type Fault = {code: string, message: string}
type Reply = {version: 1, workspace_id: string, request_id: string, op: Operation,
    ok: boolean, binding: Binding?, error: Fault?}
-- The host sends this once to its freshly spawned broker. It is a bounded
-- recovery projection, never a query surface: only unfinished work reaches
-- the broker after a workspace restart.
type Recovery = {version: 1, workspace_id: string, items: {Binding}}
type Recovered = {version: 1, workspace_id: string}

local M = {}
local MAX_REQUEST_ID = 80
local MAX_INSTANCE_ID = 80
local MAX_THREAD_ID = 160
local MAX_DEFINITION_ID = 160
local MAX_DEFINITION_REVISION = 80
local MAX_ACTOR_ID = 160
local MAX_IDEMPOTENCY_KEY = 160
local MAX_OWNER_ID = 160
local MAX_GATEWAY_BINDING_ID = 160
local MAX_GATEWAY_APPROVAL_ID = 160
local MAX_FAULT_CODE = 160
local MAX_FAULT_MESSAGE = 4096
local MAX_REVISION = 9007199254740990
local MAX_RECOVERY_ITEMS = 256

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "string" then return nil end
    end
    return value :: Object
end

local function exact(value: Object, allowed: {string}): boolean
    local fields: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do fields[name] = true end
    for key in pairs(value) do
        if not fields[key] then return false end
    end
    return true
end

local function text(value: unknown, maximum: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > maximum or value:find("[^ -~]") then return nil end
    return value
end

local function workspace(value: unknown, expected: string): string?
    if type(expected) ~= "string" or #expected ~= 32 or expected:find("[^0-9a-f]") then return nil end
    if value ~= expected then return nil end
    return expected
end

local function revision(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value)
        or value < 1 or value > MAX_REVISION then return nil end
    return math.floor(value)
end

local function digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function state(value: unknown): State?
    if value == "pending" or value == "active" or value == "revoked" then return value end
    return nil
end

local function operation(value: unknown): Operation?
    if value == "prepare" or value == "activate" or value == "refresh_join"
        or value == "begin_revoke" or value == "refresh_cleanup" or value == "finish_revoke" then return value end
    return nil
end

local function application_actor(workspace_id: string, instance_id: string): string
    return "bee.application:" .. workspace_id .. ":" .. instance_id
end

local function prepare(value: unknown, workspace_id: string): PrepareValue?
    local input = object(value)
    if not input or not exact(input, {"instance_id", "thread_id", "definition_id", "actor_id", "role", "idempotency_key",
        "definition_revision", "initiating_owner_id", "gateway_binding_id", "gateway_approval_id",
        "gateway_proposal_digest", "access", "join_expected_revision"}) then return nil end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local thread_id = text(input.thread_id, MAX_THREAD_ID)
    local definition_id = text(input.definition_id, MAX_DEFINITION_ID)
    local actor_id = text(input.actor_id, MAX_ACTOR_ID)
    local idempotency_key = text(input.idempotency_key, MAX_IDEMPOTENCY_KEY)
    local definition_revision = text(input.definition_revision, MAX_DEFINITION_REVISION)
    local initiating_owner_id = text(input.initiating_owner_id, MAX_OWNER_ID)
    local gateway_binding_id = text(input.gateway_binding_id, MAX_GATEWAY_BINDING_ID)
    local gateway_approval_id = text(input.gateway_approval_id, MAX_GATEWAY_APPROVAL_ID)
    local gateway_proposal_digest = digest(input.gateway_proposal_digest)
    local join_expected_revision = revision(input.join_expected_revision)
    if not instance_id or not thread_id or not definition_id or not actor_id or input.role ~= "participant"
        or not idempotency_key or not definition_revision or not initiating_owner_id or not gateway_binding_id
        or not gateway_approval_id or not gateway_proposal_digest or input.access ~= "observe_post"
        or not join_expected_revision then return nil end
    if actor_id ~= application_actor(workspace_id, instance_id) then return nil end
    return {instance_id = instance_id, thread_id = thread_id, definition_id = definition_id, actor_id = actor_id,
        role = "participant", idempotency_key = idempotency_key, definition_revision = definition_revision,
        initiating_owner_id = initiating_owner_id, gateway_binding_id = gateway_binding_id,
        gateway_approval_id = gateway_approval_id, gateway_proposal_digest = gateway_proposal_digest,
        access = "observe_post", join_expected_revision = join_expected_revision}
end

local function transition(value: unknown, expected: State?, extra: string?): Object?
    local names = {"instance_id", "expected_revision", "expected_state"}
    if extra then names[#names + 1] = extra end
    local input = object(value)
    if not input or not exact(input, names) then return nil end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local expected_revision = revision(input.expected_revision)
    local expected_state = state(input.expected_state)
    if not instance_id or not expected_revision or not expected_state or (expected and expected_state ~= expected) then return nil end
    if extra and not revision(input[extra]) then return nil end
    return {instance_id = instance_id, expected_revision = expected_revision, expected_state = expected_state,
        [extra or ""] = extra and revision(input[extra]) or nil}
end

local function decode_value(op: Operation, value: unknown, workspace_id: string): Value?
    if op == "prepare" then return prepare(value, workspace_id) end
    if op == "activate" then
        local decoded = transition(value, "pending", "membership_revision")
        if not decoded then return nil end
        return {instance_id = decoded.instance_id :: string, expected_revision = decoded.expected_revision :: integer,
            expected_state = "pending", membership_revision = decoded.membership_revision :: integer}
    end
    if op == "refresh_join" then
        local decoded = transition(value, "pending", "join_expected_revision")
        if not decoded then return nil end
        return {instance_id = decoded.instance_id :: string, expected_revision = decoded.expected_revision :: integer,
            expected_state = "pending", join_expected_revision = decoded.join_expected_revision :: integer}
    end
    if op == "begin_revoke" then
        local decoded = transition(value, nil, "cleanup_expected_revision")
        if not decoded or (decoded.expected_state ~= "pending" and decoded.expected_state ~= "active") then return nil end
        if decoded.expected_state == "pending" then
            return {instance_id = decoded.instance_id :: string, expected_revision = decoded.expected_revision :: integer,
                expected_state = "pending", cleanup_expected_revision = decoded.cleanup_expected_revision :: integer}
        end
        return {instance_id = decoded.instance_id :: string, expected_revision = decoded.expected_revision :: integer,
            expected_state = "active", cleanup_expected_revision = decoded.cleanup_expected_revision :: integer}
    end
    if op == "refresh_cleanup" then
        local decoded = transition(value, "revoked", "cleanup_expected_revision")
        if not decoded then return nil end
        return {instance_id = decoded.instance_id :: string, expected_revision = decoded.expected_revision :: integer,
            expected_state = "revoked", cleanup_expected_revision = decoded.cleanup_expected_revision :: integer}
    end
    local decoded = transition(value, "revoked", nil)
    if not decoded then return nil end
    return {instance_id = decoded.instance_id :: string, expected_revision = decoded.expected_revision :: integer,
        expected_state = "revoked"}
end

function M.request(value: unknown, workspace_id: string): Request?
    local input = object(value)
    if not input or not exact(input, {"version", "workspace_id", "request_id", "op", "value"})
        or input.version ~= 1 then return nil end
    local checked_workspace = workspace(input.workspace_id, workspace_id)
    local request_id = text(input.request_id, MAX_REQUEST_ID)
    local op = operation(input.op)
    if not checked_workspace or not request_id or not op then return nil end
    local decoded = decode_value(op, input.value, checked_workspace)
    if not decoded then return nil end
    return {version = 1, workspace_id = checked_workspace, request_id = request_id, op = op, value = decoded}
end

function M.binding(value: unknown, expected_workspace_id: string?): Binding?
    local input = object(value)
    if not input or not exact(input, {"instance_id", "thread_id", "definition_id", "actor_id", "role", "binding_revision", "state",
        "idempotency_key", "definition_revision", "initiating_owner_id", "gateway_binding_id", "gateway_approval_id",
        "gateway_proposal_digest", "access", "join_expected_revision", "membership_revision", "cleanup_pending",
        "cleanup_expected_revision"}) then return nil end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local thread_id = text(input.thread_id, MAX_THREAD_ID)
    local definition_id = text(input.definition_id, MAX_DEFINITION_ID)
    local actor_id = text(input.actor_id, MAX_ACTOR_ID)
    local binding_revision = revision(input.binding_revision)
    local binding_state = state(input.state)
    local idempotency_key = text(input.idempotency_key, MAX_IDEMPOTENCY_KEY)
    local definition_revision = text(input.definition_revision, MAX_DEFINITION_REVISION)
    local initiating_owner_id = text(input.initiating_owner_id, MAX_OWNER_ID)
    local gateway_binding_id = text(input.gateway_binding_id, MAX_GATEWAY_BINDING_ID)
    local gateway_approval_id = text(input.gateway_approval_id, MAX_GATEWAY_APPROVAL_ID)
    local gateway_proposal_digest = digest(input.gateway_proposal_digest)
    local join_expected_revision = revision(input.join_expected_revision)
    local membership_revision = input.membership_revision == nil and nil or revision(input.membership_revision)
    local cleanup_pending = input.cleanup_pending
    local cleanup_expected_revision = input.cleanup_expected_revision == nil and nil or revision(input.cleanup_expected_revision)
    if not instance_id or not thread_id or not definition_id or not actor_id or input.role ~= "participant"
        or not binding_revision or not binding_state or not idempotency_key or not definition_revision
        or not initiating_owner_id or not gateway_binding_id or not gateway_approval_id or not gateway_proposal_digest
        or input.access ~= "observe_post" or not join_expected_revision or (cleanup_pending ~= 0 and cleanup_pending ~= 1)
        or (input.membership_revision ~= nil and not membership_revision)
        or (input.cleanup_expected_revision ~= nil and not cleanup_expected_revision) then return nil end
    if expected_workspace_id ~= nil
        and (not workspace(expected_workspace_id, expected_workspace_id)
            or actor_id ~= application_actor(expected_workspace_id, instance_id)) then return nil end
    if binding_state == "pending" and (membership_revision ~= nil or cleanup_pending ~= 0 or cleanup_expected_revision ~= nil) then return nil end
    if binding_state == "active" and (membership_revision == nil or cleanup_pending ~= 0 or cleanup_expected_revision ~= nil) then return nil end
    if binding_state == "revoked" and ((cleanup_pending == 0 and cleanup_expected_revision ~= nil)
        or (cleanup_pending == 1 and cleanup_expected_revision == nil)) then return nil end
    local cleanup_state: 0 | 1 = cleanup_pending == 1 and 1 or 0
    return {instance_id = instance_id, thread_id = thread_id, definition_id = definition_id, actor_id = actor_id,
        role = "participant", binding_revision = binding_revision, state = binding_state, idempotency_key = idempotency_key,
        definition_revision = definition_revision, initiating_owner_id = initiating_owner_id,
        gateway_binding_id = gateway_binding_id, gateway_approval_id = gateway_approval_id,
        gateway_proposal_digest = gateway_proposal_digest, access = "observe_post",
        join_expected_revision = join_expected_revision, membership_revision = membership_revision,
        cleanup_pending = cleanup_state, cleanup_expected_revision = cleanup_expected_revision}
end

function M.recovery(value: unknown, expected_workspace_id: string): Recovery?
    local input = object(value)
    if not input or not exact(input, {"version", "workspace_id", "items"}) or input.version ~= 1
        or not workspace(input.workspace_id, expected_workspace_id) or type(input.items) ~= "table" then return nil end
    local items = input.items :: {unknown}
    local result: {Binding} = {}
    local seen: {[string]: boolean} = {}
    for index, value in ipairs(items) do
        if index > MAX_RECOVERY_ITEMS then return nil end
        local binding = M.binding(value, expected_workspace_id)
        if not binding or seen[binding.instance_id]
            or (binding.state == "revoked" and binding.cleanup_pending ~= 1) then return nil end
        seen[binding.instance_id] = true
        result[#result + 1] = binding
    end
    if #result ~= #items then return nil end
    return {version = 1, workspace_id = expected_workspace_id, items = result}
end

function M.recovered(value: unknown, expected_workspace_id: string): Recovered?
    local input = object(value)
    if not input or not exact(input, {"version", "workspace_id"}) or input.version ~= 1
        or not workspace(input.workspace_id, expected_workspace_id) then return nil end
    return {version = 1, workspace_id = expected_workspace_id}
end

function M.fault(value: unknown): Fault?
    local input = object(value)
    if not input or not exact(input, {"code", "message"}) then return nil end
    local code = text(input.code, MAX_FAULT_CODE)
    local message = input.message
    if not code or type(message) ~= "string" or #message > MAX_FAULT_MESSAGE then return nil end
    return {code = code, message = message}
end

local function expected_identity(expected: string | Request, value: Object): boolean
    if type(expected) == "string" then return workspace(value.workspace_id, expected) ~= nil end
    return value.workspace_id == expected.workspace_id and value.request_id == expected.request_id and value.op == expected.op
end

function M.reply(value: unknown, expected: string | Request): Reply?
    local input = object(value)
    if not input or not exact(input, {"version", "workspace_id", "request_id", "op", "ok", "binding", "error"})
        or input.version ~= 1 or not expected_identity(expected, input) then return nil end
    local workspace_id: string
    if type(expected) == "string" then workspace_id = expected else workspace_id = (expected :: Request).workspace_id end
    if not workspace(input.workspace_id, workspace_id) then return nil end
    local request_id = text(input.request_id, MAX_REQUEST_ID)
    local op = operation(input.op)
    if not request_id or not op or type(input.ok) ~= "boolean" then return nil end
    if input.ok then
        if input.error ~= nil or input.binding == nil then return nil end
        local binding = M.binding(input.binding, workspace_id)
        if not binding then return nil end
        return {version = 1, workspace_id = workspace_id, request_id = request_id, op = op,
            ok = true, binding = binding}
    end
    if input.binding ~= nil or input.error == nil then return nil end
    local fault = M.fault(input.error)
    if not fault then return nil end
    return {version = 1, workspace_id = workspace_id, request_id = request_id, op = op,
        ok = false, error = fault}
end

function M.success(request: Request, value: unknown): Reply?
    local binding = M.binding(value, request.workspace_id)
    if not binding then return nil end
    return {version = 1, workspace_id = request.workspace_id, request_id = request.request_id,
        op = request.op, ok = true, binding = binding}
end

function M.failure(request: Request, code: string, message: string): Reply?
    local fault = M.fault({code = code, message = message})
    if not fault then return nil end
    return {version = 1, workspace_id = request.workspace_id, request_id = request.request_id,
        op = request.op, ok = false, error = fault}
end

return M
