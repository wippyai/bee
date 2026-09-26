-- MIT. Build a safe recovery-actor revert for an activation with no applied migrations.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")

local M = {}
local RECOVERY_ACTOR = "bee.gov.recovery"
type Result = transaction.Result
type Object = {[string]: unknown}
type Activations = {
    applied: (any, string) -> Result,
    revert_activation: (any, string, Object) -> Result,
}

local function has_facts(activations: Activations, store: any, component: string): (boolean?, string?)
    local result = activations.applied(store, component)
    if not result.ok then return nil, result.message or "read applied migration facts" end
    local value = bounds.object(result.value)
    local migrations = value and bounds.object(value.migrations) or nil
    if not migrations then return nil, "applied migration facts are malformed" end
    for _ in pairs(migrations) do return true, nil end
    return false, nil
end

function M.revert(activations_raw: any, store: any, owner_raw: unknown,
    current_raw: unknown, baseline_raw: unknown, key_raw: unknown): Result
    local activations = activations_raw :: Activations
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
    return activations.revert_activation(store, RECOVERY_ACTOR, {operation = "revert_activation",
        overlay_owner = owner, expected_revision = revision, idempotency_key = key,
        compensation = {bytes = bytes, digest = digest},
        diagnostics = "headless recovery revert; no applied migration facts exist"})
end

return M
