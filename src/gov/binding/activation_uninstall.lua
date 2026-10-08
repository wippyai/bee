-- MIT. A person's removal of one governed application: the activation owner
-- records it under the person who asked, the slot stops wanting any version,
-- and the owner's registry overlay keeps only the application's databases.
-- The saved data lives in those databases; removal never touches it, and
-- installing the application again finds it as it was.
local bounds = require("bounds")
local transaction = require("transaction")
local activations = require("activation_store")

local M = {}
type Object = {[string]: unknown}
type Result = transaction.Result

-- clear takes everything but the databases off the owner's overlay and cleared
-- observes that only they remain.
type Config = {activations: activations.Store, overlay_owner: string, actor_id: string,
    clear: () -> ({[string]: unknown}?, string?), cleared: () -> (boolean?, string?)}

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end

function M.uninstall(config: Config, receipt_raw: unknown, expected_raw: unknown?): Result
    local receipt = bounds.id(receipt_raw)
    if not receipt then return failure("INVALID", "removal receipt key is invalid") end
    local expected = expected_raw ~= nil and bounds.id(expected_raw) or nil
    if expected_raw ~= nil and not expected then return failure("INVALID", "expected activation is invalid") end
    local desired = activations.desired(config.activations, config.overlay_owner)
    local removed: Object? = nil
    if desired.ok then
        local current = bounds.object(desired.value)
        local revision = current and bounds.count(current.slot_revision)
        if not current or revision == nil then return failure("INTERNAL", "desired activation is malformed") end
        if expected and current.intent_id ~= expected then return failure("CONFLICT", "installed activation differs from the approved removal") end
        if current.phase ~= "settled" or current.outcome ~= "applied" or current.intent_id ~= current.observed_intent_id then
            return failure("CONFLICT", "the application has a version on its way; let it settle before removing it")
        end
        local recorded = activations.remove_activation(config.activations, config.actor_id, {
            operation = "remove_activation", overlay_owner = config.overlay_owner, expected_revision = revision,
            idempotency_key = receipt, diagnostics = "removed by the person"})
        if not recorded.ok then return recorded end
        removed = bounds.object(recorded.value)
    elseif desired.code ~= "NOT_FOUND" then
        return desired
    end
    local off, off_error = config.cleared()
    if off == nil then return failure("UNAVAILABLE", tostring(off_error)) end
    if removed == nil and off then return failure("NOT_FOUND", "this application is not installed here") end
    if not off then
        local cleared, clear_error = config.clear()
        if not cleared then return failure("UNCERTAIN", tostring(clear_error or "take the application off its overlay"), removed) end
        local observed, observe_error = config.cleared()
        if observed ~= true then
            return failure("UNCERTAIN", tostring(observe_error or "the removed application's overlay is not observable; try again"), removed)
        end
    end
    return transaction.success(removed or {removed = true}, false)
end

return M
