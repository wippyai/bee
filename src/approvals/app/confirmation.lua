local funcs = require("funcs")
local uuid = require("uuid")
local bounds = require("bounds")
local canonical = require("canonical")
local caller = require("caller")
local M = {}
type Object = {[string]: unknown}
type Ask = (string, Object) -> caller.Envelope?
type Context = {workspace_id: string, origin: Object}
type Pending = {view: Object, target: string, action: string, presentation: string}
type State = {context: Context, ask: Ask, pending: Pending?}
local function call(target: string, request: Object): caller.Envelope?
    local raw, err = funcs.call(target, request)
    if err then return nil end
    return caller.envelope(raw)
end
local function invoke(state: State, method: string, request: Object): (Object?, string?, string?, Object?)
    local reply = state.ask("bee.approvals.binding:" .. method, request)
    if not reply then return nil, "Confirmation owner did not answer" end
    if not reply.ok then return nil, reply.error.message, reply.error.code, bounds.object(reply.value) end
    local value = bounds.object(reply.value)
    if not value then return nil, "Confirmation owner returned an invalid result" end
    return value, nil
end
function M.new(context: Context, ask: Ask?): State
    return {context = context, ask = ask or call, pending = nil}
end
function M.active(state: State): boolean return state.pending ~= nil end
function M.matches(state: State, action: string): boolean return state.pending ~= nil and state.pending.action == action end
function M.action(state: State): string return state.pending and state.pending.action or "" end
local function fence(pending: Pending): Object
    return {approval_id = pending.view.approval_id, expected_revision = pending.view.revision,
        proposal_digest = pending.view.proposal_digest, reviewed_digest = pending.view.reviewed_digest}
end
function M.cancel(state: State): (boolean, string?)
    local pending = state.pending
    if not pending then return true, nil end
    local value, err = invoke(state, "withdraw", fence(pending))
    if not value then return false, err end
    state.pending = nil
    return true, nil
end
function M.open(state: State, action: string, target: Object, presentation: "inline" | "dialog" | "inbox", title: string, message: string): (boolean, string?)
    local encoded, encode_error = canonical.encode(target)
    if not encoded then return false, tostring(encode_error) end
    local pending = state.pending
    if pending and pending.action == action and pending.target == encoded then return true, nil end
    local canceled, cancel_error = M.cancel(state)
    if not canceled then return false, cancel_error end
    local key = assert(uuid.v7())
    local value, err = invoke(state, "request", {contract_version = 2, workspace_id = state.context.workspace_id,
        idempotency_key = key, request_kind = "permission", policy = "local-confirmation", ttl_ms = 60000,
        origin = state.context.origin, presentation = presentation,
        proposal = {kind = "operation", ref = "bee.approvals:confirmation", revision = "1", payload = {action = action, target = target}},
        scope = {type = "exact", parameters = target}, prompt = {text = title .. (message ~= "" and ("\n" .. message) or "")}})
    if not value then return false, err end
    if value.state ~= "pending" or not bounds.id(value.approval_id) or not bounds.integer(value.revision)
        or not bounds.text(value.proposal_digest, 64) or not bounds.text(value.reviewed_digest, 64) then
        return false, "Confirmation request is unavailable"
    end
    state.pending = {view = value, target = encoded, action = action, presentation = presentation}
    return true, nil
end
function M.accept(state: State, target: Object, gesture: "enter" | "space" | "click" | "shortcut", decision: string?): (boolean, string?)
    local pending = state.pending
    if not pending then return false, "Open the confirmation first" end
    if canonical.encode(target) ~= pending.target then
        M.cancel(state)
        return false, "Target changed; review it again"
    end
    local request = fence(pending)
    request.decision = decision or "allow_once"
    request.assurance = {kind = "explicit_gesture", gesture = gesture, presentation = pending.presentation}
    local value, err = invoke(state, "decide", request)
    if not value then return false, err end
    if value.state ~= "decided" or value.decision ~= ((decision == "denied" or decision == "deny") and "denied" or "approved") then
        state.pending = nil
        return false, "Confirmation ended before this gesture"
    end
    if value.decision == "approved" then
        local consumption = {operation = "claim", approval_id = value.approval_id, proposal_digest = value.proposal_digest,
            effect_key = value.approval_id, owner_incarnation = value.owner_incarnation}
        local consumed, consume_error, code, conflict = invoke(state, "effect", consumption)
        if code == "REVALIDATE" and conflict then
            consumption.owner_incarnation = conflict.current_incarnation
            local validated, validation_error = invoke(state, "revalidate", {approval_id = value.approval_id,
                proposal_digest = value.proposal_digest, reviewed_digest = value.reviewed_digest, owner_incarnation = conflict.current_incarnation})
            if not validated then return false, validation_error end
            consumed, consume_error = invoke(state, "effect", consumption)
        end
        if not consumed then return false, consume_error end
    end
    state.pending = nil
    return true, nil
end
function M.gesture(event: unknown): "enter" | "space" | "click" | "shortcut"
    if type(event) == "table" then
        if event.type == "mouse" then return "click" end
        if event.key_type == "enter" then return "enter" end
        if event.key_type == "space" then return "space" end
    end
    return "shortcut"
end
return M
