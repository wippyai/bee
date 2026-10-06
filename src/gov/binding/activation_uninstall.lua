-- MIT. A person's removal of one governed application: the activation owner
-- records it under the person who asked, the slot stops wanting any version,
-- and the owner's registry overlay is emptied through the same reconcile that
-- applies a version, with no version as its target. The application's saved
-- data lives in the databases the host granted it; removal never touches
-- them, and installing the application again finds them as they were.
local bounds = require("bounds")
local transaction = require("transaction")
local activations = require("activation_store")

local M = {}
type Object = {[string]: unknown}
type Result = transaction.Result

-- clear empties the owner's overlay and cleared observes that it is empty.
type Config = {activations: activations.Store, overlay_owner: string, actor_id: string,
    clear: () -> ({[string]: unknown}?, string?), cleared: () -> (boolean?, string?)}

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end

function M.uninstall(config: Config, receipt_raw: unknown): Result
    local receipt = bounds.id(receipt_raw)
    if not receipt then return failure("INVALID", "removal receipt key is invalid") end
    local desired = activations.desired(config.activations, config.overlay_owner)
    local removed: Object? = nil
    if desired.ok then
        local current = bounds.object(desired.value)
        local revision = current and bounds.count(current.slot_revision)
        if not current or revision == nil then return failure("INTERNAL", "desired activation is malformed") end
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
    local empty, empty_error = config.cleared()
    if empty == nil then return failure("UNAVAILABLE", tostring(empty_error)) end
    if removed == nil and empty then return failure("NOT_FOUND", "this application is not installed here") end
    if not empty then
        local cleared, clear_error = config.clear()
        if not cleared then return failure("UNCERTAIN", tostring(clear_error or "empty the application's overlay"), removed) end
        local observed, observe_error = config.cleared()
        if observed ~= true then
            return failure("UNCERTAIN", tostring(observe_error or "the emptied overlay is not observable; try again"), removed)
        end
    end
    return transaction.success(removed or {removed = true}, false)
end

return M
