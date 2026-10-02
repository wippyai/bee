-- MIT. The forwarding outbox at the Threads owner boundary: the pump's
-- claim and settle calls. Both see only the caller's own rows; the
-- destination's admission decides every delivery.
local boundary = require("boundary")
local outbox = require("outbox")
local M = {}
function M.claim(request: unknown): unknown
    return boundary.run(outbox.claim_deliveries, request, true)
end
function M.settle(request: unknown): unknown
    return boundary.run(outbox.settle_delivery, request, true)
end
return M
