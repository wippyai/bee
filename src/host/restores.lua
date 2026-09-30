-- MIT. Concurrent automatic application restore scheduling. The host sends
-- every restorable record together and tracks each open until the broker
-- answers, so one slow application never serializes the rest behind it.
local records = require("records")
type Record = records.Record
type State = {queue: {Record}, inflight: {[string]: boolean}}
local M = {}
function M.new(queue: {Record}): State
    return {queue = queue, inflight = {}}
end
function M.select(state: State, available: (string) -> boolean): {Record}
    local selected: {Record} = {}
    local kept: {Record} = {}
    for _, record in ipairs(state.queue) do
        if available(record.definition_id) then selected[#selected + 1] = record
        else kept[#kept + 1] = record end
    end
    state.queue = kept
    return selected
end
function M.track(state: State, request_id: string): ()
    state.inflight[request_id] = true
end
function M.complete(state: State, request_id: string): boolean
    if not state.inflight[request_id] then return false end
    state.inflight[request_id] = nil
    return true
end
-- Deferred records wait for their definitions without holding readiness;
-- only opens the broker has not answered do.
function M.opening(state: State): boolean
    return next(state.inflight) ~= nil
end
function M.reset(state: State, queue: {Record}): ()
    state.queue = queue
    state.inflight = {}
end
return M
