-- MIT. The forwarding pump's decisions, pure: what one delivery attempt's
-- reply means for the durable outbox row behind it. A settled delivery is
-- committed on the destination's own reply; a refusal the destination made
-- final fails the row; anything that leaves the outcome unknown is never
-- settled here, so the row's lease lapses and the delivery repeats under
-- the sender's stable idempotency key. Nothing here opens a store, sends a
-- byte or names a policy.
local bounds = require("bounds")
local M = {}
-- One claim never exceeds this many deliveries.
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
return M
