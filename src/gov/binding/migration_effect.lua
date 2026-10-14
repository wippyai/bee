-- MIT. Execute one immutable Governance migration work item through the
-- existing Hub migration contract.  The activation owner supplies the work;
-- callers cannot select functions, databases, components or policies here.
local canonical = require("canonical")
local hash = require("hash")
local hub_migrations = require("hub_migrations")
local migration_runner = require("migration_runner")
local migration_work = require("migration_work")
local materializer = require("materializer")

local M = {}
type Binding = {database_id: string, table_prefix: string?}
type Bindings = {[string]: Binding}
type PolicyIds = {string}
local PRIVATE_POLICIES = {
    "bee.gov.security:destination_service_policy",
    "bee.gov.security:destination_execution_policy",
}

local function staging_owner(overlay_owner: string): (string?, string?)
    if type(overlay_owner) ~= "string" or overlay_owner == "" then return nil, "overlay owner is invalid" end
    local value = overlay_owner .. ".migrations"
    if #value > 160 then return nil, "migration prerequisite owner is too long" end
    return value, nil
end

local function definitions(work: migration_work.Work): {unknown}
    local entries: {unknown} = {}
    for _, item in ipairs(work.migrations) do entries[#entries + 1] = item.definition end
    return entries
end

-- The prerequisites of the captured migrations: the application database and
-- grant the intent provisions, installed in the application's own overlay,
-- and the migration definitions, staged apart and cleared before the
-- application is exposed.
type Provisioned = {databases: {unknown}, policies: {unknown}}

function M.matches(overlay_owner: string, work: migration_work.Work, provisioned: Provisioned): (boolean?, string?)
    local owner, owner_error = staging_owner(overlay_owner)
    if not owner then return nil, owner_error end
    local present, present_error = materializer.provides(overlay_owner, provisioned)
    if present ~= true then return present, present_error end
    return materializer.matches(owner, definitions(work))
end

function M.prepare(overlay_owner: string, work: migration_work.Work, provisioned: Provisioned): ({[string]: unknown}?, string?)
    local owner, owner_error = staging_owner(overlay_owner)
    if not owner then return nil, owner_error end
    local provided, provide_error = materializer.provide(overlay_owner, provisioned)
    if not provided then return nil, provide_error end
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

local function frozen_bindings(work: migration_work.Work): (Bindings?, string?)
    local result: Bindings = {}
    local targets: {[string]: boolean} = {}
    for _, item in ipairs(work.migrations) do targets[item.target_db] = true end
    for target in pairs(targets) do
        local item, item_error = migration_work.database(work, target)
        if not item then return nil, item_error end
        result[target] = {database_id = item.database_id, table_prefix = item.table_prefix}
    end
    return result, nil
end

function M.execute(work: migration_work.Work, execution_policies: PolicyIds?): ({bytes: string, digest: string}?, boolean, string?)
    local bindings, binding_error = frozen_bindings(work)
    if not bindings then return nil, false, binding_error end
    local entries: {hub_migrations.Entry} = {}
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
        migration_runner.source(entries, PRIVATE_POLICIES, bindings, execution_policies),
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
