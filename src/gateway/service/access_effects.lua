local funcs = require("funcs")
local bounds = require("bounds")
local gateway = require("gateway")
local subject_call = require("subject_call")
local M = {}
local DESTINATION = "gateway.access"
type Object = {[string]: unknown}
local function approvals(operation: string, request: Object): gateway.Reply
    local raw, err = funcs.call("bee.approvals.binding:" .. operation, request)
    local reply = bounds.object(raw)
    if err or not reply then return {ok = false, value = nil, error = {code = "UNAVAILABLE", message = tostring(err)}} end
    local fault = bounds.object(reply.error)
    return {ok = reply.ok == true, value = reply.value,
        error = fault and {code = tostring(fault.code), message = tostring(fault.message)} or nil}
end
local function value(operation: string, request: Object): Object
    local reply = approvals(operation, request)
    assert(reply.ok, reply.error and reply.error.message)
    return assert(bounds.object(reply.value))
end
local function events(acknowledge: boolean): boolean
    local cursor = 0
    local pending = false
    repeat
        local page = value("events", {destination = DESTINATION, cursor = cursor, limit = 64})
        local rows = assert(bounds.array(page.events, 64))
        local ids: {string} = {}
        for _, raw in ipairs(rows) do
            local event = assert(bounds.object(raw))
            if event.acknowledged_at == nil then
                pending = true
                if acknowledge and event.kind == "grant.revoked" then
                    ids[#ids + 1] = assert(bounds.id(event.event_id))
                end
            end
        end
        if acknowledge and #ids > 0 then value("events", {destination = DESTINATION, acknowledge = ids}) end
        cursor = assert(bounds.count(page.cursor))
    until #rows < 64
    return pending
end
function M.pending(): boolean
    local page = value("effect_queue", {destination = DESTINATION, limit = 1})
    return #assert(bounds.array(page.effects, 64)) > 0 or events(false)
end
function M.drain(): boolean
    repeat
        local page = value("effect_queue", {destination = DESTINATION, limit = 64})
        local rows = assert(bounds.array(page.effects, 64))
        for _, raw in ipairs(rows) do
            local view = assert(bounds.object(raw))
            local id = assert(bounds.id(view.approval_id))
            local effect = assert(bounds.object(view.effect))
            local key = assert(bounds.id(effect.effect_id))
            local result: Object = {ok = false, message = tostring(view.decision or view.state)}
            if view.state == "decided" and view.decision == "approved" and effect.state ~= "canceled" then
                local claimed = subject_call.claim_effect(approvals, id, assert(bounds.id(view.proposal_digest)), key, view.owner_incarnation)
                assert(claimed.ok, claimed.error and claimed.error.message)
                local admitted = assert(bounds.object(assert(bounds.object(claimed.value)).effect))
                value("effect", {operation = "start", approval_id = id, proposal_digest = view.proposal_digest,
                    effect_key = key, owner_incarnation = admitted.owner_incarnation, expected_revision = admitted.revision})
                local proposal = assert(bounds.object(view.proposal))
                local payload = assert(bounds.object(proposal.payload))
                local binding, missing = gateway.managed_binding(assert(bounds.id(payload.binding_id)))
                local applied = binding and gateway.apply_access(binding, id) or missing
                assert(applied, "access binding unavailable")
                if not applied.ok and applied.error and (applied.error.code == "STORAGE" or applied.error.code == "UNAVAILABLE") then
                    error(applied.error.message)
                end
                result = {ok = applied.ok, value = applied.value, error = applied.error}
            end
            value("effect", {operation = "complete", approval_id = id, proposal_digest = view.proposal_digest,
                effect_key = key, result = result})
        end
        if #rows < 64 then break end
    until false
    events(true)
    return true
end
return M
