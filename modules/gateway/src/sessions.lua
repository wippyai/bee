-- MIT. Session discovery values, pure. A session is one running managed
-- agent: the live binding of an action, under its newest carrier epoch.
-- An address names a session by its action, by one of its attempts, or by
-- its thread when that thread holds exactly one running session. Nothing
-- here reads a store or decides who may see or reach a session; the thread
-- owner's membership rules do.
local M = {}
M.MAX_SESSIONS = 64
type Candidate = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, carrier_epoch: integer}
type View = {session: string, action_id: string, attempt_id: string, thread_id: string, title: string, self: boolean}
-- One candidate per action, the newest carrier epoch winning, ordered by
-- thread and then action so a listing is stable across calls.
function M.latest(candidates: {Candidate}): {Candidate}
    local by_action: {[string]: Candidate} = {}
    for _, item in ipairs(candidates) do
        local held = by_action[item.action_id]
        if not held or item.carrier_epoch > held.carrier_epoch then by_action[item.action_id] = item end
    end
    local result: {Candidate} = {}
    for _, item in pairs(by_action) do result[#result + 1] = item end
    table.sort(result, function(left: Candidate, right: Candidate): boolean
        if left.thread_id ~= right.thread_id then return left.thread_id < right.thread_id end
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
function M.view(item: Candidate, title: string, self_action_id: string): View
    return {session = item.action_id, action_id = item.action_id, attempt_id = item.attempt_id, thread_id = item.thread_id, title = title, self = item.action_id == self_action_id}
end
return M
