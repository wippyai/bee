local caller = require("caller")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type State = {sequence: integer, decisions: {Object}, requests: {Object}, withdrawals: integer}
function M.new(): State return {sequence = 0, decisions = {}, requests = {}, withdrawals = 0} end
function M.ask(state: State, target: string, request: Object): caller.Reply?
    local result: Object = {}
    if target == "bee.approvals.binding:request" then
        state.sequence = state.sequence + 1
        state.requests[#state.requests + 1] = request
        result = {approval_id = "confirmation-" .. tostring(state.sequence), revision = 1, state = "pending",
            proposal_digest = string.rep("a", 64), reviewed_digest = string.rep("b", 64), owner_incarnation = 1}
    elseif target == "bee.approvals.binding:decide" then
        state.decisions[#state.decisions + 1] = request
        result = {approval_id = request.approval_id, revision = 2, state = "decided", decision = request.decision == "deny" and "denied" or "approved",
            proposal_digest = request.proposal_digest, reviewed_digest = request.reviewed_digest, owner_incarnation = 1}
    elseif target == "bee.approvals.binding:withdraw" then state.withdrawals = state.withdrawals + 1
    elseif target ~= "bee.approvals.binding:effect" or request.operation ~= "claim" then return nil end
    return {ok = true, error = nil, value = result}
end
function M.gesture(state: State, index: integer): string?
    local record = state.decisions[index]
    local assurance = record and bounds.object(record.assurance)
    return assurance and bounds.text(assurance.gesture, 32) or nil
end
return M
