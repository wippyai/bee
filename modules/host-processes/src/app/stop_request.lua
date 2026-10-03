-- Bounded wait state for the broker-owned application stop request.
local M = {}

type Pending = {request_id: string}

function M.begin(request_id: string): Pending
    return {request_id = request_id}
end

function M.matches(pending: Pending?, request_id: unknown): boolean
    return pending ~= nil and request_id == pending.request_id
end

return M
