local funcs = require("funcs")
local committed = require("committed")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
local function call(person: funcs.Executor, operation: string, request: Object): Object
    local raw, err = person:call("bee.approvals.binding:" .. operation, request)
    assert(not err, tostring(err))
    local reply = assert(bounds.object(raw))
    local fault = bounds.object(reply.error)
    assert(reply.ok == true, fault and tostring(fault.message))
    return assert(bounds.object(reply.value))
end
function M.decide(person: funcs.Executor, approval_id: unknown, decision: string): Object
    local question = call(person, "read", {approval_id = approval_id})
    local effect = bounds.object(question.effect)
    local function decide(): Object
        return call(person, "decide", {approval_id = approval_id, decision = decision, expected_revision = question.revision,
            proposal_digest = question.proposal_digest, reviewed_digest = question.reviewed_digest})
    end
    if effect and effect.destination == "gateway.access" then
        local first = true
        local decided = committed.await({"bee_approval_requests"}, function(): Object
            if first then first = false; decide() end
            return call(person, "read", {approval_id = approval_id})
        end, function(value: Object): boolean return value.effect_completed_at ~= nil end, nil, "approval effect")
        if decision == "approved" then assert(assert(bounds.object(decided.effect_result)).ok == true, "approval effect failed") end
    else decide() end
    return question
end
return M
