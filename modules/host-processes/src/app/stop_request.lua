-- Bounded wait state for the broker-owned application stop request.
local M = {}
M.TIMEOUT_TICKS = 5
M.TIMEOUT = "Stop result timed out; refresh before retrying"

type Pending = {request_id: string, ticks: integer}

function M.begin(request_id: string): Pending
    return {request_id = request_id, ticks = 0}
end

function M.matches(pending: Pending?, request_id: unknown): boolean
    return pending ~= nil and request_id == pending.request_id
end

function M.tick(pending: Pending?): (Pending?, string?)
    if not pending then return nil, nil end
    local ticks: integer = pending.ticks + 1
    if ticks >= M.TIMEOUT_TICKS then return nil, M.TIMEOUT end
    return {request_id = pending.request_id, ticks = ticks}, nil
end

return M
