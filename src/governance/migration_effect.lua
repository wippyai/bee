-- MIT. Execute one immutable Governance migration work item through the
-- existing Hub migration contract.  The activation owner supplies the work;
-- callers cannot select functions, databases, components or policies here.
local canonical = require("canonical")
local hash = require("hash")
local hub_migrations = require("hub_migrations")
local migration_runner = require("migration_runner")
local materializer = require("materializer")

local M = {}
local PRIVATE_POLICIES = {
    "bee:governance_destination_service_policy",
    "bee:governance_destination_execution_policy",
}

local function staging_owner(overlay_owner: string): (string?, string?)
    if type(overlay_owner) ~= "string" or overlay_owner == "" then return nil, "overlay owner is invalid" end
    local value = overlay_owner .. ".migrations"
    if #value > 160 then return nil, "migration prerequisite owner is too long" end
    return value, nil
end

local function definitions(work: any): {unknown}
    local entries: {unknown} = {}
    for _, item in ipairs(work.migrations) do entries[#entries + 1] = item.definition end
    return entries
end

function M.matches(overlay_owner: string, work: any): (boolean?, string?)
    local owner, owner_error = staging_owner(overlay_owner)
    if not owner then return nil, owner_error end
    return materializer.matches(owner, definitions(work))
end

function M.prepare(overlay_owner: string, work: any): ({[string]: unknown}?, string?)
    local owner, owner_error = staging_owner(overlay_owner)
    if not owner then return nil, owner_error end
    return materializer.reconcile(owner, definitions(work))
end

function M.clear(overlay_owner: string): ({[string]: unknown}?, string?)
    local owner, owner_error = staging_owner(overlay_owner)
    if not owner then return nil, owner_error end
    return materializer.reconcile(owner, {})
end

function M.cleared(overlay_owner: string): (boolean?, string?)
    local owner, owner_error = staging_owner(overlay_owner)
    if not owner then return nil, owner_error end
    return materializer.matches(owner, {})
end

function M.execute(work: any): ({bytes: string, digest: string}?, boolean, string?)
    local entries: {any} = {}
    local ids: {string} = {}
    local components: {string} = {}
    local seen_components: {[string]: boolean} = {}
    for _, item in ipairs(work.migrations) do
        entries[#entries + 1] = {id = item.id,
            meta = {type = "migration", target_db = item.target_db,
                timestamp = string.format("%016d", item.ordinal)},
            registry = {owner = item.package}}
        ids[#ids + 1] = item.id
        if not seen_components[item.package] then
            seen_components[item.package] = true
            components[#components + 1] = item.package
        end
    end
    table.sort(components)
    local result, execute_error = hub_migrations.execute(
        migration_runner.source(entries, PRIVATE_POLICIES),
        {operation = "up", entry_ids = ids, components = components})
    if not result then return nil, false, execute_error or "execute captured migrations" end
    local bytes, encode_error = canonical.encode({schema_revision = "bee.governance-migration-receipt@1",
        rows = result.rows}, 262144)
    if not bytes then return nil, false, tostring(encode_error or "encode migration receipt") end
    local digest, digest_error = hash.sha256(bytes)
    if not digest then return nil, false, tostring(digest_error or "measure migration receipt") end
    return {bytes = bytes, digest = digest}, execute_error == nil, execute_error
end

return M
