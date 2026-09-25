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
-- The node forwarding pump's claim and settle. Unlike the sender-scoped
-- methods these cross every sender the node holds: the pump is the node's own
-- forwarding owner, and the storage policy a host attaches to these entries
-- is what authorizes that reach.
function M.claim_pump(request: unknown): unknown
    return boundary.run(outbox.claim_pump_due, request, true)
end
function M.settle_pump(request: unknown): unknown
    return boundary.run(outbox.settle_pump, request, true)
end
return M
