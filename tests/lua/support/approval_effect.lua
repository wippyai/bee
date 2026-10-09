local funcs = require("funcs")
local cdc = require("cdc")
local channel = require("channel")
local time = require("time")
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
    local changes = effect and effect.destination == "gateway.access" and assert(cdc.stream("bee:changes", {tables = {"bee_approval_requests"}, ops = {"update"}})) or nil
    local decided = call(person, "decide", {approval_id = approval_id, decision = decision, expected_revision = question.revision,
        proposal_digest = question.proposal_digest, reviewed_digest = question.reviewed_digest})
    if changes then
        local deadline = time.after("20s")
        local source = changes:channel()
        while decided.effect_completed_at == nil do
            local selected = channel.select({source:case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel ~= deadline, "approval effect did not complete")
            decided = call(person, "read", {approval_id = approval_id})
        end
        changes:close()
        if decision == "approved" then assert(assert(bounds.object(decided.effect_result)).ok == true, "approval effect failed") end
    end
    return question
end
return M
