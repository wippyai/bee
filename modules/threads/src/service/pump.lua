-- MIT. The forwarding pump's decisions, pure: what one delivery attempt's
-- reply means for the durable outbox row behind it. A settled delivery is
-- committed on the destination's own reply; a refusal the destination made
-- final fails the row; anything that leaves the outcome unknown is never
-- settled here, so the row's lease lapses and the delivery repeats under
-- the sender's stable idempotency key. Nothing here opens a store, sends a
-- byte or names a policy.
local bounds = require("bounds")
local M = {}
-- One claim never exceeds this many deliveries, and one attempt's outcome
-- is one of these three decisions.
M.BATCH = 16
type Object = {[string]: unknown}
type Outcome = {decision: string, code: string?, message: string?, receipt: unknown?}
-- Reply codes the destination has made final: repeating the identical
-- delivery cannot succeed, so the row fails rather than retrying forever.
local FINAL: {[string]: boolean} = {
    DENIED = true, NOT_FOUND = true, CONFLICT = true, INVALID_ARGUMENT = true, INVALID_STATE = true,
    UNSUPPORTED_CAPABILITY = true, FORBIDDEN = true, UNAUTHENTICATED = true, LIMIT_EXCEEDED = true, SCHEMA_MISMATCH = true,
}
-- outcome: classify one delivery attempt. "delivered" carries the owner's
-- receipt; "failed" carries the final refusal; "unknown" settles nothing.
-- A transport error is always unknown: the destination may have committed.
function M.outcome(reply: unknown, transport_error: unknown): Outcome
    if transport_error ~= nil then
        return {decision = "unknown", code = "UNAVAILABLE", message = tostring(transport_error), receipt = nil}
    end
    local envelope = bounds.object(reply)
    if not envelope then return {decision = "unknown", code = "INVALID_REPLY", message = "destination reply is malformed", receipt = nil} end
    if envelope.ok == true then return {decision = "delivered", code = nil, message = nil, receipt = envelope.value} end
    local fault = bounds.object(envelope.error)
    if not fault then return {decision = "unknown", code = "INVALID_REPLY", message = "destination refusal is malformed", receipt = nil} end
    local code = bounds.id(fault.code) or "INTERNAL"
    local message = type(fault.message) == "string" and (fault.message :: string) or "delivery refused"
    if FINAL[code] then return {decision = "failed", code = code, message = message, receipt = nil} end
    return {decision = "unknown", code = code, message = message, receipt = nil}
end
-- claim_request: a pump's own claim is bounded and names only the holder and
-- an optional page size, like the sender-scoped claim.
function M.claim_request(request: unknown): ({holder: string, limit: integer}?, string?)
    local object = bounds.object(request)
    if not object then return nil, "request must be an object" end
    local extra = bounds.fields(object, {"holder", "limit"})
    if extra then return nil, extra end
    local holder = bounds.id(object.holder)
    if not holder then return nil, "holder is not an identifier" end
    local limit = M.BATCH
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > M.BATCH then return nil, "limit is bounded by the outbox batch" end
        limit = number
    end
    return {holder = holder, limit = limit}, nil
end
-- settle_request: the pump's acknowledgment. It names the row and the
-- attempt's decision; only a delivered attempt carries a receipt, and only a
-- failed one carries an error. An unknown outcome is not a settle.
function M.settle_request(request: unknown): ({outbox_id: string, delivered: boolean, receipt: unknown?, error: string?}?, string?)
    local object = bounds.object(request)
    if not object then return nil, "request must be an object" end
    local extra = bounds.fields(object, {"outbox_id", "delivered", "receipt", "error"})
    if extra then return nil, extra end
    local outbox_id = bounds.id(object.outbox_id)
    if not outbox_id or type(object.delivered) ~= "boolean" then return nil, "outbox_id and delivered are required" end
    local delivered: boolean = object.delivered == true
    if delivered and object.error ~= nil then return nil, "a delivered attempt carries no error" end
    if not delivered and object.receipt ~= nil then return nil, "a failed attempt carries no receipt" end
    local error_text: string? = nil
    if object.error ~= nil then
        error_text = bounds.text(object.error)
        if error_text == nil then return nil, "error must be text" end
    end
    return {outbox_id = outbox_id, delivered = delivered, receipt = object.receipt, error = error_text}, nil
end
return M
