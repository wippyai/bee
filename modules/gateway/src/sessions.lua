-- MIT. Live carrier bindings, pure: one candidate per action under its newest
-- carrier epoch. Nothing here reads a store or decides who may see a session.
local M = {}
type Candidate = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, carrier_epoch: integer, name: string?}
-- One candidate per action, the newest carrier epoch winning, ordered by
-- action ID so a listing is stable across calls.
function M.latest(candidates: {Candidate}): {Candidate}
    local by_action: {[string]: Candidate} = {}
    for _, item in ipairs(candidates) do
        local held = by_action[item.action_id]
        if not held or item.carrier_epoch > held.carrier_epoch then by_action[item.action_id] = item end
    end
    local result: {Candidate} = {}
    for _, item in pairs(by_action) do result[#result + 1] = item end
    table.sort(result, function(left: Candidate, right: Candidate): boolean
        return left.action_id < right.action_id
    end)
    return result
end
return M
