-- MIT. Governance owns migration of all owner_node partitions in its store.
-- Foreign keys are disabled only for this one checked transaction so related
-- composite keys can move together; the transaction checks all references
-- before recording completion.
local sql = require("sql")
local env = require("env")
local bounds = require("bounds")
local M = {}

local TABLES: {string} = {
    "bee_governance_workspace_files",
    "bee_governance_snapshot_files",
    "bee_governance_receipts",
    "bee_governance_snapshots",
    "bee_governance_workspaces",
    "bee_governance_plan_receipts",
    "bee_governance_plan_selection",
    "bee_governance_plan_slots",
    "bee_governance_plans",
    "bee_governance_activation_execution",
    "bee_governance_activation_receipts",
    "bee_governance_activation_reverts",
    "bee_governance_applied_migrations",
    "bee_governance_activation_slots",
    "bee_governance_activation_slot",
    "bee_governance_activation_intents",
}
local SOURCE_NODE_TABLES: {string} = {
    "bee_governance_plans",
    "bee_governance_plan_selection",
    "bee_governance_plan_receipts",
    "bee_governance_plan_slots",
    "bee_governance_activation_intents",
}

function M.apply(db: sql.DB, destination_raw: unknown, source_override: unknown?): (boolean, string?)
    local destination = bounds.id(destination_raw)
    if not destination then return false, "governance destination node identity is invalid" end
    local source_raw: unknown = source_override
    if source_raw == nil then
        local source, env_error = env.get("bee.gov:node_identity_migration_source")
        if env_error then
            if env_error:kind() == errors.NOT_FOUND then return true, nil end
            return false, "read governance legacy node identity: " .. tostring(env_error)
        end
        source_raw = source
    end
    if source_raw == nil or source_raw == "" then return true, nil end
    local source = bounds.id(source_raw)
    if not source then return false, "governance legacy node identity is invalid" end
    if source == destination then return true, nil end

    local prior, prior_error = db:query(
        "SELECT destination_node FROM bee_governance_node_identity_migrations WHERE source_node = ?", {source})
    if prior_error or not prior then return false, "read governance node identity migration ledger: " .. tostring(prior_error) end
    if #prior > 0 then
        if #prior == 1 and prior[1].destination_node == destination then return true, nil end
        return false, "governance legacy node identity was already migrated to another destination"
    end

    local tx, begin_error = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return false, "begin governance identity migration: " .. tostring(begin_error or "unknown error") end
    local function fail(message: string): (boolean, string?)
        local rolled_back, rollback_error = tx:rollback()
        if rolled_back ~= true or rollback_error then
            message = message .. "; rollback governance identity migration: " .. tostring(rollback_error or "no reason given")
        end
        return false, message
    end

    local _, defer_error = tx:execute("PRAGMA defer_foreign_keys = ON")
    if defer_error then return fail("defer governance foreign keys for identity migration: " .. tostring(defer_error)) end

    local raced, raced_error = tx:query(
        "SELECT destination_node FROM bee_governance_node_identity_migrations WHERE source_node = ?", {source})
    if raced_error or not raced then return fail("recheck governance node identity migration ledger: " .. tostring(raced_error)) end
    if #raced > 0 then
        local rolled_back, rollback_error = tx:rollback()
        if rolled_back ~= true or rollback_error then
            return false, "rollback governance identity migration: " .. tostring(rollback_error or "no reason given")
        end
        if #raced == 1 and raced[1].destination_node == destination then return true, nil end
        return false, "governance legacy node identity was already migrated to another destination"
    end

    for _, table_name in ipairs(TABLES) do
        local _, update_error = tx:execute("UPDATE " .. table_name .. " SET owner_node = ? WHERE owner_node = ?",
            {destination, source})
        if update_error then
            return fail("migrate governance owner_node rows in " .. table_name
                .. "; conflicting destination records cannot be merged safely: " .. tostring(update_error))
        end
    end
    for _, table_name in ipairs(SOURCE_NODE_TABLES) do
        local _, update_error = tx:execute("UPDATE " .. table_name .. " SET source_node = ? WHERE source_node = ?",
            {destination, source})
        if update_error then
            return fail("migrate governance local source_node rows in " .. table_name
                .. "; conflicting destination records cannot be merged safely: " .. tostring(update_error))
        end
    end

    local violations, check_error = tx:query("PRAGMA foreign_key_check")
    if check_error or not violations then return fail("check governance references after node identity migration: " .. tostring(check_error)) end
    if #violations > 0 then return fail("governance node identity migration leaves broken references") end

    local _, record_error = tx:execute([[INSERT INTO bee_governance_node_identity_migrations
(source_node, destination_node, migrated_at)
VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))]], {source, destination})
    if record_error then return fail("record governance node identity migration: " .. tostring(record_error)) end
    local committed, commit_error = tx:commit()
    if committed ~= true or commit_error then
        return fail("commit governance node identity migration: " .. tostring(commit_error))
    end
    return true, nil
end

return M
