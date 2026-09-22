-- MIT. The owner-runtime incarnation: one row per store, advanced once when
-- the module's owner process starts, read by every claim and subscription.
-- Nothing else advances it; a waiter or a caller only consumes it. The
-- authority id names this durable owner store once for its lifetime, so
-- incarnations compare only within one authority; a replaced node or a
-- reset store is another authority and never a higher number.
local sql = require("sql")
local uuid = require("uuid")
local M = {}
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
-- Advances the incarnation for this owner lifetime and returns it.
function M.establish(db: sql.DB): (integer?, string?)
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return nil, "begin owner incarnation" end
    local _, upsert_err = tx:execute(
        "INSERT INTO bee_thread_owner (singleton, incarnation, started_at) VALUES (1, 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')) " ..
        "ON CONFLICT(singleton) DO UPDATE SET incarnation = incarnation + 1, started_at = excluded.started_at")
    if upsert_err then
        tx:rollback()
        return nil, "advance owner incarnation"
    end
    local rows, query_err = tx:query("SELECT incarnation, authority_id FROM bee_thread_owner WHERE singleton = 1")
    if query_err or not rows or #rows ~= 1 then
        tx:rollback()
        return nil, "read owner incarnation"
    end
    local incarnation = integer(rows[1].incarnation)
    if not incarnation then
        tx:rollback()
        return nil, "owner incarnation is corrupt"
    end
    if type(rows[1].authority_id) ~= "string" then
        local authority_id, id_err = uuid.v4()
        if id_err or not authority_id then
            tx:rollback()
            return nil, "allocate owner authority id"
        end
        local _, set_err = tx:execute("UPDATE bee_thread_owner SET authority_id = ? WHERE singleton = 1 AND authority_id IS NULL", {authority_id})
        if set_err then
            tx:rollback()
            return nil, "record owner authority id"
        end
    end
    local committed, commit_err = tx:commit()
    if commit_err or committed ~= true then
        tx:rollback()
        return nil, "commit owner incarnation"
    end
    return incarnation, nil
end
-- The incarnation inside a transaction; nil until an owner has started.
function M.current(tx: sql.Transaction): (integer?, string?)
    local rows, query_err = tx:query("SELECT incarnation FROM bee_thread_owner WHERE singleton = 1")
    if query_err or not rows then return nil, "read owner incarnation" end
    if #rows == 0 then return nil, nil end
    local incarnation = integer(rows[1].incarnation)
    if not incarnation then return nil, "owner incarnation is corrupt" end
    return incarnation, nil
end
-- The durable authority id; nil until an owner has started.
function M.authority(tx: sql.Transaction): (string?, string?)
    local rows, query_err = tx:query("SELECT authority_id FROM bee_thread_owner WHERE singleton = 1")
    if query_err or not rows then return nil, "read owner authority" end
    if #rows == 0 or type(rows[1].authority_id) ~= "string" then return nil, nil end
    return rows[1].authority_id :: string, nil
end
return M
