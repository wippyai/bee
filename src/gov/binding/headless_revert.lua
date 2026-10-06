-- MIT. Build a safe revert to the retained earlier version, by the recovery
-- actor or, when a person asks for it, by that person. Migrations are forward
-- only: going back runs none and rolls none back, so it is allowed only when the
-- earlier version already defines every migration applied to the application.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local activation_store = require("activation_store")
local artifact = require("artifact")

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

type Applied = {id: string, target_db: string}

-- applied lists the migrations applied to the component, in database and id order.
local function applied(activations: Activations, store: Store, component: string): ({Applied}?, string?)
    local result = activations.applied(store, component)
    if not result.ok then return nil, result.message or "read applied migration facts" end
    local value = bounds.object(result.value)
    local migrations = value and bounds.object(value.migrations) or nil
    if not migrations then return nil, "applied migration facts are malformed" end
    local found: {Applied} = {}
    for _, raw in pairs(migrations) do
        local fact = bounds.object(raw)
        local id, target_db = fact and bounds.text(fact.id, 256), fact and bounds.text(fact.target_db, 256)
        if not id or not target_db then return nil, "applied migration facts are malformed" end
        found[#found + 1] = {id = id, target_db = target_db}
    end
    table.sort(found, function(a: Applied, b: Applied): boolean
        if a.target_db ~= b.target_db then return a.target_db < b.target_db end
        return a.id < b.id
    end)
    return found, nil
end

-- defined names the migrations the earlier version's exact artifact carries.
local function defined_by(baseline: Object): ({[string]: boolean}?, string?)
    local entries, decode_error = artifact.decode(baseline.artifact_bytes, baseline.artifact_digest)
    if not entries then return nil, "read the earlier version's definitions: " .. tostring(decode_error) end
    local defined: {[string]: boolean} = {}
    for _, entry in ipairs(entries) do
        local meta = bounds.object(entry.meta)
        local target_db = meta and meta.type == "migration" and bounds.text(meta.target_db, 256) or nil
        local id = bounds.text(entry.id, 256)
        if target_db and id then defined[target_db .. "\n" .. id] = true end
    end
    return defined, nil
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
    local facts: {Applied} = {}
    for component in pairs(components) do
        local found, facts_error = applied(activations, store, component)
        if not found then return transaction.failure("UNAVAILABLE", tostring(facts_error)) end
        for _, item in ipairs(found) do facts[#facts + 1] = item end
    end
    if #facts > 0 then
        local defined, defined_error = defined_by(baseline)
        if not defined then return transaction.failure("UNAVAILABLE", tostring(defined_error)) end
        local ids, databases, named = {}, {}, {}
        for _, item in ipairs(facts) do
            if not defined[item.target_db .. "\n" .. item.id] then
                ids[#ids + 1] = item.id
                if not named[item.target_db] then named[item.target_db] = true; databases[#databases + 1] = item.target_db end
            end
        end
        if #ids > 0 then
            return transaction.failure("BLOCKED", "Going back to " .. tostring(bounds.id(baseline.version) or "the earlier version")
                .. " is not possible: a later version changed the saved data in " .. table.concat(databases, ", ")
                .. " (" .. table.concat(ids, ", ") .. "), and that change stays. Install a newer version instead.")
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
        diagnostics = "revert to the earlier version; it defines every applied migration, so none runs or rolls back"})
end

return M
