-- MIT. Live binding identities used to address transcript operations. Durable
-- session discovery and lifecycle belong to bee.sessions.
local M = {}
type Candidate = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, carrier_epoch: integer}
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
-- Resolves an address among visible sessions: an action first, then an
-- attempt, then a thread with one session. Returns the session, or a code
-- and message naming why none was chosen.
function M.resolve(candidates: {Candidate}, address: string): (Candidate?, string?, string?)
    for _, item in ipairs(candidates) do
        if item.action_id == address then return item, nil, nil end
    end
    for _, item in ipairs(candidates) do
        if item.attempt_id == address then return item, nil, nil end
    end
    local on_thread: {Candidate} = {}
    for _, item in ipairs(candidates) do
        if item.thread_id == address then on_thread[#on_thread + 1] = item end
    end
    if #on_thread == 1 then return on_thread[1], nil, nil end
    if #on_thread > 1 then
        local actions: {string} = {}
        for index, item in ipairs(on_thread) do actions[index] = item.action_id end
        return nil, "AMBIGUOUS", "thread " .. address .. " holds " .. tostring(#on_thread) .. " running sessions; name one by action: " .. table.concat(actions, ", ")
    end
    return nil, "NOT_FOUND", "no running session you can reach is named " .. address
end
return M
