-- MIT. The resource store owns moving its node-scoped rows from the state's
-- recorded legacy identity to its persisted identity.
local sql = require("sql")
local env = require("env")
local bounds = require("bounds")
local M = {}

local function rollback(tx: sql.Transaction)
    tx:rollback()
end

local function count(tx: sql.Transaction, statement: string, args: {unknown}): (integer?, string?)
    local rows, err = tx:query(statement, args)
    if err or not rows or #rows ~= 1 or type(rows[1].count) ~= "number" then
        return nil, "read resource node identity migration count"
    end
    local value = math.floor(rows[1].count)
    if value < 0 or value ~= rows[1].count then return nil, "resource node identity migration count is invalid" end
    return value, nil
end

function M.apply(db: sql.DB, destination_raw: unknown, source_override: unknown?): (boolean, string?)
    local source_raw: unknown = source_override
    if source_raw == nil then
        local source, env_error = env.get("bee.resources.env:node_identity_migration_source")
        if env_error then
            if env_error:kind() == errors.NOT_FOUND then return true, nil end
            return false, "read resource legacy node identity: " .. tostring(env_error)
        end
        source_raw = source
    end
    if source_raw == nil or source_raw == "" then return true, nil end
    local source, destination = bounds.id(source_raw), bounds.id(destination_raw)
    if not source or not destination then return false, "resource node identity migration identity is invalid" end
    if source == destination then return true, nil end

    local tx, begin_error = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return false, "begin resource node identity migration" end
    local function fail(message: string): (boolean, string?)
        rollback(tx)
        return false, message
    end

    local prior, prior_error = tx:query(
        "SELECT destination_node FROM bee_resource_node_identity_migrations WHERE source_node = ?", {source})
    if prior_error or not prior then return fail("read resource node identity migration ledger") end
    if #prior > 0 then
        rollback(tx)
        if #prior == 1 and prior[1].destination_node == destination then return true, nil end
        return false, "resource legacy node identity was already migrated to another destination"
    end

    local collisions, collision_error = count(tx, [[SELECT COUNT(*) AS count
FROM bee_resource_associations legacy
JOIN bee_resource_associations current
  ON current.workspace_id = legacy.workspace_id AND current.name = legacy.name
WHERE legacy.owner_node = ? AND current.owner_node = ?]], {source, destination})
    if collision_error or collisions == nil then return fail(collision_error or "check resource association collisions") end
    if collisions > 0 then
        return fail("resource identity migration found associations already owned by the destination node")
    end

    local association_count, association_error = count(tx,
        "SELECT COUNT(*) AS count FROM bee_resource_associations WHERE owner_node = ?", {source})
    if association_error or association_count == nil then return fail(association_error or "count resource associations") end
    local grant_count, grant_error = count(tx,
        "SELECT COUNT(*) AS count FROM bee_resource_grants WHERE issuer_owner = ? OR audience = ?", {source, source})
    if grant_error or grant_count == nil then return fail(grant_error or "count resource grants") end

    local _, association_update_error = tx:execute(
        "UPDATE bee_resource_associations SET owner_node = ? WHERE owner_node = ?", {destination, source})
    if association_update_error then return fail("migrate resource associations") end
    local _, grants_update_error = tx:execute(
        "UPDATE bee_resource_grants SET issuer_owner = ? WHERE issuer_owner = ?", {destination, source})
    if grants_update_error then return fail("migrate resource grant issuers") end
    local _, audience_update_error = tx:execute(
        "UPDATE bee_resource_grants SET audience = ? WHERE audience = ?", {destination, source})
    if audience_update_error then return fail("migrate resource grant audiences") end
    local _, record_error = tx:execute([[INSERT INTO bee_resource_node_identity_migrations
(source_node, destination_node, migrated_at, association_count, grant_count)
VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?, ?)]],
        {source, destination, association_count, grant_count})
    if record_error then return fail("record resource node identity migration") end

    local committed, commit_error = tx:commit()
    if committed ~= true or commit_error then
        rollback(tx)
        return false, "commit resource node identity migration"
    end
    return true, nil
end

return M
