-- MIT. Application broker-to-Threads binding protocol and effect orchestration.
--
-- The broker retains application lifecycle ownership. This module owns the
-- thread binding reducer's effects and the values sent across its boundaries.
local bounds = require("bounds")
local principal = require("principal")
local binding_protocol = require("binding_protocol")
local reducer = require("reducer")
local contract = require("contract")
local open_protocol = require("open_protocol")
local lifecycle = require("lifecycle")
local security = require("security")

type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, replayed: boolean,
    error: {code: string, message: string, retryable: boolean}?}
type Binding = {instance_id: string, thread_id: string, actor_id: string,
    role: "participant", initiating_owner_id: string}
type Membership = {head_revision: integer, membership_revision: integer}
type MembershipStatus = {state: "active" | "absent" | "unknown", head_revision: integer?, membership_revision: integer?}
type Open = {request: contract.Request, provenance: open_protocol.Provenance,
    descriptor: contract.Descriptor, binding: contract.Binding, scope: security.Scope,
    view_id: string, instance_id: string, existing: boolean}
type Coordinator = {instance_id: string, state: reducer.State, open: Open?, retry_at: number,
    failure_code: string?, failure_message: string?, stop_event: lifecycle.Event?, settle_after_revoke: boolean?,
    effect: reducer.Effect?}
type Engine = {coordinators: {[string]: Coordinator}, requests: {[string]: string}}
type Context = {workspace_id: string, now: () -> number, new_id: () -> string,
    send_host: (string, string, binding_protocol.Request) -> boolean,
    thread_call: (string, string, unknown) -> (unknown?, string?), emit: (contract.Reply, boolean?) -> (),
    stop_after_revoke: (string, lifecycle.Event, boolean) -> (), launch: (Coordinator) -> ()}
type Outcome = "success" | "conflict" | "unknown"

local M = {}
local MAX_WORKSPACE_ID = 32

function M.new(): Engine
    return {coordinators = {}, requests = {}}
end

function M.new_coordinator(instance_id: string): Coordinator
    return {instance_id = instance_id, state = reducer.new(), open = nil, retry_at = 0}
end

function M.reset(coordinator: Coordinator): ()
    coordinator.state = reducer.new()
end

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
    return principal.actor_id(workspace_id, instance_id)
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
    if not summary or not member or not exact(summary, {"thread_id", "title", "state", "revision", "head_sequence", "owner_id", "created_at", "workspace_id"})
        or not exact(member, {"member_id", "role", "revision", "active"}) then return nil end
    if summary.workspace_id ~= nil and not workspace(summary.workspace_id) then return nil end
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

local function outcome(reply: Reply?): Outcome
    if reply and reply.ok then return "success" end
    if reply and reply.error and reply.error.code == "CONFLICT" then return "conflict" end
    return "unknown"
end

local function finish(engine: Engine, context: Context, coordinator: Coordinator, terminal: reducer.Terminal)
    if terminal == "active" then
        if coordinator.open then context.launch(coordinator) end
    elseif terminal == "retry" then
        coordinator.retry_at = context.now() + 0.2
    elseif terminal == "cleanup_pending" then
        coordinator.retry_at = context.now() + 1
    else
        local binding = coordinator.state.binding
        if terminal == "failed" and binding then
            coordinator.retry_at = context.now() + 0.2
            return
        end
        if coordinator.open then
            context.emit(contract.reply(coordinator.open.request.request_id, "open",
                coordinator.failure_code or "permission_denied",
                coordinator.failure_message or "Application thread access was revoked"), true)
        end
        for request_id, instance_id in pairs(engine.requests) do
            if instance_id == coordinator.instance_id then engine.requests[request_id] = nil end
        end
        engine.coordinators[coordinator.instance_id] = nil
    end
end

local function run_effect(engine: Engine, context: Context, coordinator: Coordinator, effect: reducer.Effect?)
    if not effect then return end
    coordinator.effect = effect
    if type(effect) == "string" then finish(engine, context, coordinator, effect); return end
    if type(effect) ~= "table" then error("Reducer produced an invalid application binding effect") end

    local binding = coordinator.state.binding
    if effect.kind == "host" then
        local request_id = context.new_id()
        local request = binding_protocol.request({version = 1, workspace_id = context.workspace_id,
            request_id = request_id, op = effect.op, value = effect.value}, context.workspace_id)
        if not request then error("Reducer produced an invalid application binding request") end
        local instance_id = binding and binding.instance_id or coordinator.open and coordinator.open.instance_id or ""
        engine.requests[request_id] = instance_id
        if not context.send_host(request_id, instance_id, request) then
            engine.requests[request_id] = nil
            coordinator.retry_at = context.now() + 0.2
        else
            coordinator.effect = nil
        end
    elseif not binding then
        finish(engine, context, coordinator, "failed")
    elseif effect.kind == "membership" then
        local request = M.get_request(binding, context.workspace_id)
        if effect.principal == "application" then
            local reply = request and context.thread_call(binding.actor_id, "bee.threads.service:get", request) or nil
            local status = M.application_status(reply, binding, context.workspace_id)
            M.drive(engine, context, coordinator, {kind = "membership", principal = "application", purpose = effect.purpose,
                state = status.state, head_revision = status.head_revision, membership_revision = status.membership_revision})
        else
            local reply = request and context.thread_call(binding.initiating_owner_id, "bee.threads.service:get", request) or nil
            local raw_purpose = effect.purpose
            if not raw_purpose then error("Reducer membership effect has no purpose") end
            local purpose: reducer.Purpose = raw_purpose
            local revision = purpose == "cleanup_refresh" and M.owner_head(reply, binding, context.workspace_id)
                or M.owner_get(reply, binding, context.workspace_id)
            local state: "active" | "unknown" = revision and "active" or "unknown"
            local event: reducer.Event = {kind = "membership", principal = "owner", purpose = purpose,
                state = state, head_revision = revision}
            M.drive(engine, context, coordinator, event)
        end
    elseif effect.kind == "join" then
        local request = M.join_request(binding, context.workspace_id, binding.idempotency_key, effect.expected_revision)
        local reply, err = nil, nil
        if request then reply, err = context.thread_call(binding.initiating_owner_id, "bee.threads.service:join", request) end
        local status = outcome(M.reply(reply))
        if err then status = "unknown" end
        M.drive(engine, context, coordinator, {kind = "join", outcome = status})
    else
        local request = M.leave_request(binding, context.workspace_id, binding.idempotency_key .. "-leave", effect.expected_revision)
        local reply = request and context.thread_call(binding.initiating_owner_id, "bee.threads.service:leave", request) or nil
        M.drive(engine, context, coordinator, {kind = "leave", outcome = outcome(M.reply(reply))})
    end
end

function M.run_effect(engine: Engine, context: Context, coordinator: Coordinator, effect: reducer.Effect?): ()
    run_effect(engine, context, coordinator, effect)
end

function M.drive(engine: Engine, context: Context, coordinator: Coordinator, event: reducer.Event): ()
    local was_revoke = event.kind == "host" and event.op == "begin_revoke" and event.outcome == "success"
    local state, effect = reducer.reduce(coordinator.state, event)
    coordinator.state = state
    if was_revoke and coordinator.open and coordinator.failure_code then
        context.emit(contract.reply(coordinator.open.request.request_id, "open", coordinator.failure_code,
            coordinator.failure_message or "Application thread access was revoked"), true)
        coordinator.open = nil
    end
    if was_revoke and coordinator.stop_event then
        local binding = coordinator.state.binding
        if binding then
            context.stop_after_revoke(binding.instance_id, coordinator.stop_event, coordinator.settle_after_revoke == true)
        end
        coordinator.stop_event = nil
        coordinator.settle_after_revoke = nil
    end
    run_effect(engine, context, coordinator, effect)
end

function M.fail(engine: Engine, context: Context, coordinator: Coordinator, code: string, message: string): ()
    coordinator.failure_code, coordinator.failure_message = code, message
    M.drive(engine, context, coordinator, {kind = "revoke"})
end

return M
