-- MIT. Credentials owns moving its node-local definitions and projection
-- issuer/audience references to the state's persisted identity.
local sql = require("sql")
local env = require("env")
local bounds = require("bounds")
local M = {}

local function count(tx: sql.Transaction, statement: string, args: {unknown}): (integer?, string?)
    local rows, err = tx:query(statement, args)
    if err or not rows or #rows ~= 1 or type(rows[1].count) ~= "number" then
        return nil, "read credential node identity migration count"
    end
    local value = math.floor(rows[1].count)
    if value < 0 or value ~= rows[1].count then return nil, "credential node identity migration count is invalid" end
    return value, nil
end

function M.apply(db: sql.DB, destination_raw: unknown, source_override: unknown?): (boolean, string?)
    local source_raw: unknown = source_override
    if source_raw == nil then
        local source, env_error = env.get("bee.credentials:node_identity_migration_source")
        if env_error then
            if env_error:kind() == errors.NOT_FOUND then return true, nil end
            return false, "read credential legacy node identity: " .. tostring(env_error)
        end
        source_raw = source
    end
    if source_raw == nil or source_raw == "" then return true, nil end
    local source, destination = bounds.id(source_raw), bounds.id(destination_raw)
    if not source or not destination then return false, "credential node identity migration identity is invalid" end
    if source == destination then return true, nil end

    local tx, begin_error = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return false, "begin credential node identity migration" end
    local function fail(message: string): (boolean, string?)
        tx:rollback()
        return false, message
    end

    local prior, prior_error = tx:query(
        "SELECT destination_node FROM bee_credential_node_identity_migrations WHERE source_node = ?", {source})
    if prior_error or not prior then return fail("read credential node identity migration ledger") end
    if #prior > 0 then
        tx:rollback()
        if #prior == 1 and prior[1].destination_node == destination then return true, nil end
        return false, "credential legacy node identity was already migrated to another destination"
    end

    local definition_count, definition_error = count(tx,
        "SELECT COUNT(*) AS count FROM bee_credential_definitions WHERE owner_node = ?", {source})
    if definition_error or definition_count == nil then return fail(definition_error or "count credential definitions") end
    local projection_count, projection_error = count(tx,
        "SELECT COUNT(*) AS count FROM bee_credential_projections WHERE issuer_owner = ? OR audience = ?", {source, source})
    if projection_error or projection_count == nil then return fail(projection_error or "count credential projections") end

    local _, definitions_update_error = tx:execute(
        "UPDATE bee_credential_definitions SET owner_node = ? WHERE owner_node = ?", {destination, source})
    if definitions_update_error then return fail("migrate credential definitions") end
    local _, issuer_update_error = tx:execute(
        "UPDATE bee_credential_projections SET issuer_owner = ? WHERE issuer_owner = ?", {destination, source})
    if issuer_update_error then return fail("migrate credential projection issuers") end
    local _, audience_update_error = tx:execute(
        "UPDATE bee_credential_projections SET audience = ? WHERE audience = ?", {destination, source})
    if audience_update_error then return fail("migrate credential projection audiences") end
    local _, record_error = tx:execute([[INSERT INTO bee_credential_node_identity_migrations
(source_node, destination_node, migrated_at, definition_count, projection_count)
VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?, ?)]],
        {source, destination, definition_count, projection_count})
    if record_error then return fail("record credential node identity migration") end

    local committed, commit_error = tx:commit()
    if committed ~= true or commit_error then
        tx:rollback()
        return false, "commit credential node identity migration"
    end
    return true, nil
end

return M
