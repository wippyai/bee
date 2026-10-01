-- MIT. Approvals owns moving its node-local authority and request rows from
-- the state's recorded legacy identity to its persisted identity.
local sql = require("sql")
local env = require("env")
local bounds = require("bounds")
local M = {}

local function count(tx: sql.Transaction, statement: string, args: {unknown}): (integer?, string?)
    local rows, err = tx:query(statement, args)
    if err or not rows or #rows ~= 1 or type(rows[1].count) ~= "number" then
        return nil, "read approval node identity migration count"
    end
    local value = math.floor(rows[1].count)
    if value < 0 or value ~= rows[1].count then return nil, "approval node identity migration count is invalid" end
    return value, nil
end

function M.apply(db: sql.DB, destination_raw: unknown, source_override: unknown?): (boolean, string?)
    local source_raw: unknown = source_override
    if source_raw == nil then
        local source, env_error = env.get("bee.approvals:node_identity_migration_source")
        if env_error then
            if env_error:kind() == errors.NOT_FOUND then return true, nil end
            return false, "read approval legacy node identity: " .. tostring(env_error)
        end
        source_raw = source
    end
    if source_raw == nil or source_raw == "" then return true, nil end
    local source, destination = bounds.id(source_raw), bounds.id(destination_raw)
    if not source or not destination then return false, "approval node identity migration identity is invalid" end
    if source == destination then return true, nil end

    local tx, begin_error = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return false, "begin approval node identity migration" end
    local function fail(message: string): (boolean, string?)
        tx:rollback()
        return false, message
    end

    local prior, prior_error = tx:query(
        "SELECT destination_node FROM bee_approval_node_identity_migrations WHERE source_node = ?", {source})
    if prior_error or not prior then return fail("read approval node identity migration ledger") end
    if #prior > 0 then
        tx:rollback()
        if #prior == 1 and prior[1].destination_node == destination then return true, nil end
        return false, "approval legacy node identity was already migrated to another destination"
    end

    local authority_count, authority_error = count(tx,
        "SELECT COUNT(*) AS count FROM bee_approval_authority WHERE owner_node = ?", {source})
    if authority_error or authority_count == nil then return fail(authority_error or "count approval authorities") end
    local request_count, request_error = count(tx,
        "SELECT COUNT(*) AS count FROM bee_approval_requests WHERE owner_node = ?", {source})
    if request_error or request_count == nil then return fail(request_error or "count approval requests") end

    local _, authority_update_error = tx:execute(
        "UPDATE bee_approval_authority SET owner_node = ? WHERE owner_node = ?", {destination, source})
    if authority_update_error then return fail("migrate approval authority; a destination authority already exists") end
    local _, request_update_error = tx:execute(
        "UPDATE bee_approval_requests SET owner_node = ? WHERE owner_node = ?", {destination, source})
    if request_update_error then return fail("migrate approval requests") end
    local _, record_error = tx:execute([[INSERT INTO bee_approval_node_identity_migrations
(source_node, destination_node, migrated_at, authority_count, request_count)
VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?, ?)]],
        {source, destination, authority_count, request_count})
    if record_error then return fail("record approval node identity migration") end

    local committed, commit_error = tx:commit()
    if committed ~= true or commit_error then
        tx:rollback()
        return false, "commit approval node identity migration"
    end
    return true, nil
end

return M
