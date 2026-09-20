-- MIT. Pure application broker-to-Threads binding values.
--
-- This is deliberately below the broker lifecycle: it knows how to prove the
-- two memberships and build the three authority requests, but owns no call,
-- retry, persistence, or authorization decision.
local bounds = require("bounds")

type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, replayed: boolean,
    error: {code: string, message: string, retryable: boolean}?}
type Binding = {instance_id: string, thread_id: string, actor_id: string,
    role: "participant", initiating_owner_id: string}
type Membership = {head_revision: integer, membership_revision: integer}
type MembershipStatus = {state: "active" | "absent" | "unknown", head_revision: integer?, membership_revision: integer?}

local M = {}
local MAX_WORKSPACE_ID = 32

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: Object
end

local function exact(value: Object, allowed: {string}): boolean
    local fields: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do fields[name] = true end
    for name in pairs(value) do if not fields[name] then return false end end
    return true
end

local function revision(value: unknown): integer?
    local result = bounds.integer(value)
    if not result or result < 1 or result > 9007199254740990 then return nil end
    return result
end

local function workspace(value: unknown): string?
    if type(value) ~= "string" or #value ~= MAX_WORKSPACE_ID or value:find("[^0-9a-f]") then return nil end
    return value
end

function M.actor(workspace_id: unknown, instance_id: unknown): string?
    local checked_workspace = workspace(workspace_id)
    local checked_instance = bounds.id(instance_id)
    if not checked_workspace or not checked_instance then return nil end
    return "bee.application:" .. checked_workspace .. ":" .. checked_instance
end

local function binding(value: unknown, workspace_id: unknown): Binding?
    local input = object(value)
    local actor = input and M.actor(workspace_id, input.instance_id)
    local thread_id = input and bounds.id(input.thread_id)
    local owner = input and bounds.id(input.initiating_owner_id)
    if not input or not actor or input.actor_id ~= actor or not thread_id or not owner or input.role ~= "participant" then return nil end
    return {instance_id = input.instance_id :: string, thread_id = thread_id, actor_id = actor,
        role = "participant", initiating_owner_id = owner}
end

function M.reply(value: unknown): Reply?
    local input = object(value)
    if not input or not exact(input, {"ok", "value", "error", "replayed"})
        or type(input.ok) ~= "boolean" or type(input.replayed) ~= "boolean" then return nil end
    if input.ok then
        if input.error ~= nil then return nil end
        return {ok = true, value = input.value, replayed = input.replayed}
    end
    local failure = object(input.error)
    local code = failure and bounds.id(failure.code)
    local message = failure and bounds.text(failure.message, bounds.MAX_FAULT_MESSAGE_BYTES)
    if not failure or not exact(failure, {"code", "message", "retryable"}) or not code or not message
        or type(failure.retryable) ~= "boolean" or input.value ~= nil then return nil end
    local checked_code: string = code or ""
    local checked_message: string = message or ""
    return {ok = false, value = nil, replayed = input.replayed,
        error = {code = checked_code, message = checked_message, retryable = failure.retryable :: boolean}}
end

local function get_value(reply: unknown, thread_id: string, allow_closed: boolean?): Object?
    local decoded = M.reply(reply)
    local input = decoded and decoded.ok and object(decoded.value)
    if not input or not exact(input, {"summary", "membership"}) then return nil end
    local summary, member = object(input.summary), object(input.membership)
    if not summary or not member or not exact(summary, {"thread_id", "title", "state", "revision", "head_sequence", "owner_id", "created_at"})
        or not exact(member, {"member_id", "role", "revision", "active"}) then return nil end
    local valid_state = summary.state == "open" or (allow_closed == true and summary.state == "closed")
    if summary.thread_id ~= thread_id or not bounds.line(summary.title, bounds.MAX_TITLE_BYTES)
        or not valid_state or not revision(summary.revision)
        or not bounds.cursor(summary.head_sequence) or not bounds.id(summary.owner_id) or not bounds.timestamp(summary.created_at)
        or not bounds.id(member.member_id) or (member.role ~= "owner" and member.role ~= "participant" and member.role ~= "observer")
        or not revision(member.revision) or type(member.active) ~= "boolean" then return nil end
    return input
end

function M.owner_get(reply: unknown, value: unknown, workspace_id: unknown): integer?
    local selected = binding(value, workspace_id)
    if not selected then return nil end
    local result = get_value(reply, selected.thread_id, false)
    local summary, member = result and object(result.summary), result and object(result.membership)
    if not summary or not member or summary.owner_id ~= selected.initiating_owner_id
        or member.member_id ~= selected.initiating_owner_id or member.role ~= "owner" or member.active ~= true then return nil end
    return revision(summary.revision)
end

-- Cleanup may still need the thread head after its owner closed the thread.
-- This decoder only proves the owner/head identity; callers must still use
-- the ordinary leave operation, whose authority and state checks remain in
-- the Threads service. It is never used to authorize a new join.
function M.owner_head(reply: unknown, value: unknown, workspace_id: unknown): integer?
    local selected = binding(value, workspace_id)
    if not selected then return nil end
    local result = get_value(reply, selected.thread_id, true)
    local summary, member = result and object(result.summary), result and object(result.membership)
    if not summary or not member or summary.owner_id ~= selected.initiating_owner_id
        or member.member_id ~= selected.initiating_owner_id or member.role ~= "owner" or member.active ~= true then return nil end
    return revision(summary.revision)
end

function M.application_status(reply: unknown, value: unknown, workspace_id: unknown): MembershipStatus
    local selected = binding(value, workspace_id)
    if not selected then return {state = "unknown", head_revision = nil, membership_revision = nil} end
    local decoded = M.reply(reply)
    if not decoded then return {state = "unknown", head_revision = nil, membership_revision = nil} end
    if not decoded.ok then
        local failure = decoded.error
        if failure and (failure.code == "DENIED" or failure.code == "NOT_FOUND") then
            return {state = "absent", head_revision = nil, membership_revision = nil}
        end
        return {state = "unknown", head_revision = nil, membership_revision = nil}
    end
    local result = get_value(reply, selected.thread_id, false)
    local summary, member = result and object(result.summary), result and object(result.membership)
    if not summary or not member then return {state = "unknown", head_revision = nil, membership_revision = nil} end
    local head_revision, membership_revision = revision(summary.revision), revision(member.revision)
    if not head_revision or not membership_revision then
        return {state = "unknown", head_revision = nil, membership_revision = nil}
    end
    if member.member_id ~= selected.actor_id then
        return {state = "unknown", head_revision = nil, membership_revision = nil}
    end
    if member.role ~= "participant" or member.active ~= true then
        return {state = "absent", head_revision = head_revision, membership_revision = membership_revision}
    end
    return {state = "active", head_revision = head_revision, membership_revision = membership_revision}
end

function M.application_get(reply: unknown, value: unknown, workspace_id: unknown): Membership?
    local status = M.application_status(reply, value, workspace_id)
    if status.state ~= "active" or not status.head_revision or not status.membership_revision then return nil end
    return {head_revision = status.head_revision, membership_revision = status.membership_revision}
end

function M.get_request(value: unknown, workspace_id: unknown): Object?
    local selected = binding(value, workspace_id)
    if not selected then return nil end
    return {thread_id = selected.thread_id}
end

local function mutation(value: unknown, workspace_id: unknown, idempotency_key: unknown,
    expected_revision: unknown, leave: boolean): Object?
    local selected = binding(value, workspace_id)
    local key = bounds.id(idempotency_key)
    local expected = revision(expected_revision)
    if not selected or not key or not expected then return nil end
    return {thread_id = selected.thread_id, idempotency_key = key, member_id = selected.actor_id,
        role = leave and nil or "participant", expected_revision = expected}
end

function M.join_request(value: unknown, workspace_id: unknown, idempotency_key: unknown, expected_revision: unknown): Object?
    return mutation(value, workspace_id, idempotency_key, expected_revision, false)
end

function M.leave_request(value: unknown, workspace_id: unknown, idempotency_key: unknown, expected_revision: unknown): Object?
    local request = mutation(value, workspace_id, idempotency_key, expected_revision, true)
    if request then request.role = nil end
    return request
end

return M
