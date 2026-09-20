-- MIT. Pure application/thread binding lifecycle decisions.
-- The broker supplies decoded events and executes the one returned effect.
local binding_protocol = require("binding_protocol")

type Binding = binding_protocol.Binding
type Prepare = binding_protocol.PrepareValue
type HostOperation = "prepare" | "activate" | "refresh_join" | "begin_revoke" | "refresh_cleanup" | "finish_revoke"
type Principal = "owner" | "application"
type Purpose = "join" | "after_join" | "after_unknown_join" | "active_recovery"
    | "cleanup" | "join_refresh" | "cleanup_refresh"
type Terminal = "active" | "fenced" | "cleanup_pending" | "retry" | "failed"
type Outstanding =
    {kind: "host", op: HostOperation, value: {[string]: unknown}}
    | {kind: "membership", principal: Principal, purpose: Purpose}
    | {kind: "join", expected_revision: integer}
    | {kind: "leave", expected_revision: integer}
type Effect = Outstanding | Terminal
type State = {binding: Binding?, intent: "continue" | "revoke", outstanding: Outstanding?,
    join_refresh_used: boolean, cleanup_refresh_used: boolean, terminal: Terminal?}
type HostEvent = {kind: "host", op: HostOperation, outcome: "success" | "failure" | "unknown", binding: Binding?}
type MembershipEvent = {kind: "membership", principal: Principal, purpose: Purpose,
    state: "active" | "absent" | "unknown", head_revision: integer?, membership_revision: integer?}
type Event = {kind: "open", value: Prepare} | {kind: "recover", binding: Binding} | HostEvent
    | MembershipEvent | {kind: "join", outcome: "success" | "conflict" | "unknown"}
    | {kind: "leave", outcome: "success" | "conflict" | "unknown"} | {kind: "revoke"}
type Result = {state: State, effect: Effect?}

local M = {}
local function out(state: State, effect: Effect?): Result return {state = state, effect = effect} end
local function copy(state: State, binding: Binding?, pending: Outstanding?, terminal: Terminal?): State
    return {binding = binding, intent = state.intent, outstanding = pending,
        join_refresh_used = state.join_refresh_used, cleanup_refresh_used = state.cleanup_refresh_used, terminal = terminal}
end
local function issue(state: State, effect: Outstanding): Result return out(copy(state, state.binding, effect, nil), effect) end
local function finish(state: State, terminal: Terminal): Result return out(copy(state, state.binding, nil, terminal), terminal) end
local function host(state: State, op: HostOperation, value: {[string]: unknown}): Result
    return issue(state, {kind = "host", op = op, value = value})
end
local function membership(state: State, principal: Principal, purpose: Purpose): Result
    return issue(state, {kind = "membership", principal = principal, purpose = purpose})
end

local function same_identity(left: Binding, right: Binding): boolean
    return left.instance_id == right.instance_id and left.thread_id == right.thread_id
        and left.definition_id == right.definition_id and left.actor_id == right.actor_id
        and left.role == right.role and left.idempotency_key == right.idempotency_key
        and left.definition_revision == right.definition_revision and left.initiating_owner_id == right.initiating_owner_id
        and left.gateway_binding_id == right.gateway_binding_id and left.gateway_approval_id == right.gateway_approval_id
        and left.gateway_proposal_digest == right.gateway_proposal_digest and left.access == right.access
end
local function same_prepare(value: Prepare, binding: Binding): boolean
    return value.instance_id == binding.instance_id and value.thread_id == binding.thread_id
        and value.definition_id == binding.definition_id and value.actor_id == binding.actor_id
        and value.role == binding.role and value.idempotency_key == binding.idempotency_key
        and value.definition_revision == binding.definition_revision and value.initiating_owner_id == binding.initiating_owner_id
        and value.gateway_binding_id == binding.gateway_binding_id and value.gateway_approval_id == binding.gateway_approval_id
        and value.gateway_proposal_digest == binding.gateway_proposal_digest and value.access == binding.access
        and value.join_expected_revision == binding.join_expected_revision
end

local function begin_revoke(state: State): Result
    local binding = state.binding
    if not binding then return finish(state, "failed") end
    if binding.state == "revoked" then
        if binding.cleanup_pending == 1 then return membership(state, "application", "cleanup") end
        return finish(state, "fenced")
    end
    -- Fence with the stored owner/head revision; cleanup may use one refresh.
    return host(state, "begin_revoke", {instance_id = binding.instance_id,
        expected_revision = binding.binding_revision, expected_state = binding.state,
        cleanup_expected_revision = binding.join_expected_revision})
end
local function join(state: State): Result
    local binding = state.binding
    if not binding then return finish(state, "failed") end
    return issue(state, {kind = "join", expected_revision = binding.join_expected_revision})
end
local function activate(state: State, revision: integer): Result
    local binding = state.binding
    if not binding then return finish(state, "failed") end
    return host(state, "activate", {instance_id = binding.instance_id,
        expected_revision = binding.binding_revision, expected_state = "pending", membership_revision = revision})
end
local function finish_revoke(state: State): Result
    local binding = state.binding
    if not binding then return finish(state, "failed") end
    return host(state, "finish_revoke", {instance_id = binding.instance_id,
        expected_revision = binding.binding_revision, expected_state = "revoked"})
end
local function host_failure(state: State, op: HostOperation): Result
    if op == "refresh_cleanup" or op == "finish_revoke" then return finish(state, "cleanup_pending") end
    return finish(state, "failed")
end

local function host_result(state: State, event: HostEvent): Result
    local pending = state.outstanding
    if not pending or pending.kind ~= "host" or pending.op ~= event.op then return out(state, nil) end
    if event.outcome ~= "success" or not event.binding then return host_failure(state, event.op) end
    local binding, expected = event.binding, pending.value
    if event.op == "prepare" then
        if binding.state ~= "pending" or binding.cleanup_pending ~= 0 or not same_prepare(expected :: Prepare, binding) then
            return finish(state, "failed")
        end
        local next: State = copy(state, binding, nil, nil)
        if next.intent == "revoke" then return begin_revoke(next) end
        return join(next)
    end
    if not state.binding or not same_identity(state.binding, binding) then return finish(state, "failed") end
    if event.op == "refresh_join" then
        if binding.state ~= "pending" or binding.cleanup_pending ~= 0
            or expected.join_expected_revision ~= binding.join_expected_revision then return finish(state, "failed") end
        local next: State = copy(state, binding, nil, nil)
        if next.intent == "revoke" then return begin_revoke(next) end
        return join(next)
    end
    if event.op == "activate" then
        if binding.state ~= "active" or binding.cleanup_pending ~= 0
            or binding.membership_revision ~= expected.membership_revision then return finish(state, "failed") end
        local next: State = copy(state, binding, nil, nil)
        if next.intent == "revoke" then return begin_revoke(next) end
        return finish(next, "active")
    end
    if event.op == "begin_revoke" then
        if binding.state ~= "revoked" or binding.cleanup_pending ~= 1
            or binding.cleanup_expected_revision ~= expected.cleanup_expected_revision then return finish(state, "failed") end
        return membership(copy(state, binding, nil, nil), "application", "cleanup")
    end
    if event.op == "refresh_cleanup" then
        if binding.state ~= "revoked" or binding.cleanup_pending ~= 1
            or binding.cleanup_expected_revision ~= expected.cleanup_expected_revision then return finish(state, "cleanup_pending") end
        return issue(copy(state, binding, nil, nil), {kind = "leave", expected_revision = binding.cleanup_expected_revision :: integer})
    end
    if binding.state ~= "revoked" or binding.cleanup_pending ~= 0 then return finish(state, "cleanup_pending") end
    return finish(copy(state, binding, nil, nil), "fenced")
end

local function owner_read(state: State, purpose: "join_refresh" | "cleanup_refresh"): Result
    return membership(state, "owner", purpose)
end
local function membership_result(state: State, event: MembershipEvent): Result
    local pending, binding = state.outstanding, state.binding
    if not pending or pending.kind ~= "membership" or pending.principal ~= event.principal
        or pending.purpose ~= event.purpose then return out(state, nil) end
    if not binding then return finish(state, "failed") end
    if event.principal == "owner" then
        if event.state == "active" and not event.head_revision then return finish(state, "failed") end
        if event.purpose == "join_refresh" then
            if event.state ~= "active" or state.join_refresh_used then return begin_revoke(state) end
            local next: State = copy(state, binding, nil, nil); next.join_refresh_used = true
            return host(next, "refresh_join", {instance_id = binding.instance_id,
                expected_revision = binding.binding_revision, expected_state = "pending",
                join_expected_revision = event.head_revision :: integer})
        end
        if event.state ~= "active" or state.cleanup_refresh_used then return finish(state, "cleanup_pending") end
        local next: State = copy(state, binding, nil, nil); next.cleanup_refresh_used = true
        return host(next, "refresh_cleanup", {instance_id = binding.instance_id,
            expected_revision = binding.binding_revision, expected_state = "revoked",
            cleanup_expected_revision = event.head_revision :: integer})
    end
    if event.state == "unknown" then
        if state.intent == "revoke" then return begin_revoke(state) end
        -- Recovery uncertainty preserves the durable delegation. The broker
        -- retries it and must not acknowledge startup reconciliation yet.
        if event.purpose == "active_recovery" then return finish(state, "retry") end
        if event.purpose == "cleanup" then return finish(state, "cleanup_pending") end
        if event.purpose == "after_unknown_join" then return finish(state, "retry") end
        return finish(state, "failed")
    end
    if event.purpose == "cleanup" then
        if event.state == "active" then
            if event.membership_revision ~= binding.membership_revision then
                return finish(state, "cleanup_pending")
            end
            return issue(state, {kind = "leave", expected_revision = binding.cleanup_expected_revision :: integer})
        end
        return finish_revoke(state)
    end
    if event.purpose == "active_recovery" then
        if event.state == "active" and event.membership_revision == binding.membership_revision then
            if state.intent == "revoke" then return begin_revoke(state) end
            return finish(state, "active")
        end
        -- Absence or a changed epoch fences the durable row before cleanup.
        return begin_revoke(state)
    end
    if event.state == "active" then
        if not event.membership_revision then return finish(state, "failed") end
        if state.intent == "revoke" then return begin_revoke(state) end
        return activate(state, event.membership_revision)
    end
    if state.intent == "revoke" then return begin_revoke(state) end
    if event.purpose == "after_unknown_join" and not state.join_refresh_used then return owner_read(state, "join_refresh") end
    if event.purpose == "after_join" then return begin_revoke(state) end
    return join(state)
end

local function join_result(state: State, outcome: "success" | "conflict" | "unknown"): Result
    if not state.outstanding or state.outstanding.kind ~= "join" then return out(state, nil) end
    if outcome == "conflict" then
        if state.intent == "revoke" or state.join_refresh_used then return begin_revoke(state) end
        return owner_read(state, "join_refresh")
    end
    return membership(state, "application", outcome == "success" and "after_join" or "after_unknown_join")
end
local function leave_result(state: State, outcome: "success" | "conflict" | "unknown"): Result
    if not state.outstanding or state.outstanding.kind ~= "leave" then return out(state, nil) end
    if outcome == "success" then return finish_revoke(state) end
    if outcome == "conflict" and not state.cleanup_refresh_used then return owner_read(state, "cleanup_refresh") end
    return finish(state, "cleanup_pending")
end
local function revoke(state: State): Result
    local next: State = copy(state, state.binding, state.outstanding, nil); next.intent = "revoke"
    local binding, pending = next.binding, next.outstanding
    if not binding then
        if pending then return out(next, nil) end
        return finish(next, "failed")
    end
    if binding.state == "revoked" then
        if binding.cleanup_pending == 0 then return finish(next, "fenced") end
        if not pending then return membership(next, "application", "cleanup") end
        return out(next, nil)
    end
    -- Do not cancel a join or host transition that may have changed the row.
    if pending and (pending.kind == "join" or pending.kind == "host"
        or (pending.kind == "membership" and pending.principal == "application") or pending.kind == "leave") then
        return out(next, nil)
    end
    return begin_revoke(next)
end

function M.new(): State
    return {binding = nil, intent = "continue", outstanding = nil,
        join_refresh_used = false, cleanup_refresh_used = false, terminal = nil}
end
function M.reduce(state: State, event: Event): (State, Effect?)
    local result: Result
    if state.terminal ~= nil and event.kind ~= "revoke" then return state, nil end
    if event.kind == "revoke" then result = revoke(state)
    elseif event.kind == "open" then
        if state.binding or state.outstanding or state.intent ~= "continue" then return state, nil end
        result = host(state, "prepare", event.value)
    elseif event.kind == "recover" then
        if state.binding or state.outstanding then return state, nil end
        local next: State = copy(state, event.binding, nil, nil)
        if event.binding.state == "revoked" then
            next.intent = "revoke"
            result = event.binding.cleanup_pending == 0 and finish(next, "fenced")
                or membership(next, "application", "cleanup")
        elseif event.binding.state == "active" then
            result = event.binding.membership_revision == nil and finish(next, "failed")
                or membership(next, "application", "active_recovery")
        else
            -- A pending row replays its idempotent join before observing it.
            result = join(next)
        end
    elseif event.kind == "host" then result = host_result(state, event)
    elseif event.kind == "membership" then result = membership_result(state, event)
    elseif event.kind == "join" then result = join_result(state, event.outcome)
    else result = leave_result(state, event.outcome) end
    return result.state, result.effect
end

return M
