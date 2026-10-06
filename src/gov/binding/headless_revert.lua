-- MIT. Build a safe revert for an activation with no applied migrations, by the
-- recovery actor or, when a person asks for it, by that person.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local activation_store = require("activation_store")

local M = {}
local RECOVERY_ACTOR = "bee.gov.recovery"
type Result = transaction.Result
type Object = {[string]: unknown}
type Store = activation_store.Store
type Request = activation_store.Request
type Activations = {
    applied: (Store, string) -> Result,
    revert_activation: (Store, string, Request) -> Result,
}

local function has_facts(activations: Activations, store: Store, component: string): (boolean?, string?)
    local result = activations.applied(store, component)
    if not result.ok then return nil, result.message or "read applied migration facts" end
    local value = bounds.object(result.value)
    local migrations = value and bounds.object(value.migrations) or nil
    if not migrations then return nil, "applied migration facts are malformed" end
    for _ in pairs(migrations) do return true, nil end
    return false, nil
end

function M.revert(activations: Activations, store: Store, owner_raw: unknown,
    current_raw: unknown, baseline_raw: unknown, key_raw: unknown, actor_raw: unknown?): Result
    local owner = bounds.id(owner_raw)
    local current, baseline = bounds.object(current_raw), bounds.object(baseline_raw)
    local key = bounds.id(key_raw)
    local revision = current and bounds.count(current.slot_revision) or nil
    local current_component = current and bounds.text(current.component, 160) or nil
    local baseline_component = baseline and bounds.text(baseline.component, 160) or nil
    if not owner or not current or not baseline or current.overlay_owner ~= owner
        or baseline.overlay_owner ~= owner or not key or not revision or revision < 0
        or not current_component or current_component == "" or not baseline_component or baseline_component == "" then
        return transaction.failure("INVALID", "headless revert identity is invalid")
    end
    local components: {[string]: boolean} = {}
    components[current_component] = true
    components[baseline_component] = true
    for component in pairs(components) do
        local present, facts_error = has_facts(activations, store, component)
        if present == nil then return transaction.failure("UNAVAILABLE", tostring(facts_error)) end
        if present then
            return transaction.failure("BLOCKED", "applied migration facts exist for " .. component
                .. "; provide and apply a forward-only compensation plan before reverting")
        end
    end
    local bytes, encode_error = canonical.encode({schema_revision = "bee.governance-migration-receipt@1", rows = {}})
    if not bytes then return transaction.failure("INTERNAL", tostring(encode_error or "measure empty migration receipt")) end
    local digest, hash_error = hash.sha256(bytes)
    if not digest or hash_error then return transaction.failure("INTERNAL", "measure empty migration receipt") end
    local actor = actor_raw == nil and RECOVERY_ACTOR or bounds.id(actor_raw)
    if not actor then return transaction.failure("INVALID", "headless revert actor is invalid") end
    return activations.revert_activation(store, actor, {operation = "revert_activation",
        overlay_owner = owner, expected_revision = revision, idempotency_key = key,
        compensation = {bytes = bytes, digest = digest},
        diagnostics = "headless recovery revert; no applied migration facts exist"})
end

return M
