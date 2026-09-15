-- MIT. Durable per-destination feed progress. A cursor advances only after a
-- complete ordered page or pinned snapshot has been transferred.
local sql = require("sql")
local bounds = require("bounds")
local database = require("database")
local transaction = require("transaction")

local M = {}
type Result = transaction.Result
type Store = {db: sql.DB, closed: boolean}

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

function M.open(resource: string): (Store?, string?)
    local db, open_error = database.open(resource)
    if not db then return nil, open_error end
    return {db = db, closed = false}, nil
end

function M.cursor(store: Store, source_raw: unknown, feed_raw: unknown, destination_raw: unknown): Result
    if store.closed then return failure("CLOSED", "distribution cursor store is closed") end
    local source, feed, destination = bounds.id(source_raw), bounds.id(feed_raw), bounds.id(destination_raw)
    if not source or not feed or not destination then return failure("INVALID", "distribution cursor identity is invalid") end
    return transaction.write(store.db, "sync distribution", function(tx: sql.Transaction): Result
        local _, insert_error = tx:execute([[INSERT INTO bee_sync_distribution_cursors
(source_owner, feed, destination_node, cursor) VALUES (?, ?, ?, 0)
ON CONFLICT(source_owner, feed, destination_node) DO NOTHING]], {source, feed, destination})
        if insert_error then return failure("INTERNAL", "create distribution cursor") end
        local rows, query_error = tx:query([[SELECT cursor FROM bee_sync_distribution_cursors
WHERE source_owner = ? AND feed = ? AND destination_node = ?]], {source, feed, destination})
        local value = rows and rows[1] and bounds.count(rows[1].cursor, 9007199254740991) or nil
        if query_error or not rows or #rows ~= 1 or value == nil then return failure("INTERNAL", "read distribution cursor") end
        return transaction.success({source_owner = source, feed = feed, destination_node = destination, cursor = value}, false)
    end)
end

function M.advance(store: Store, source_raw: unknown, feed_raw: unknown, destination_raw: unknown,
    expected_raw: unknown, next_raw: unknown): Result
    if store.closed then return failure("CLOSED", "distribution cursor store is closed") end
    local source, feed, destination = bounds.id(source_raw), bounds.id(feed_raw), bounds.id(destination_raw)
    local expected = bounds.count(expected_raw, 9007199254740991)
    local next_cursor = bounds.count(next_raw, 9007199254740991)
    if not source or not feed or not destination or expected == nil or next_cursor == nil or next_cursor < expected then
        return failure("INVALID", "distribution cursor checkpoint is invalid")
    end
    return transaction.write(store.db, "sync distribution", function(tx: sql.Transaction): Result
        local changed, update_error = tx:execute([[UPDATE bee_sync_distribution_cursors SET cursor = ?
WHERE source_owner = ? AND feed = ? AND destination_node = ? AND cursor = ?]],
            {next_cursor, source, feed, destination, expected})
        if update_error or not changed then return failure("INTERNAL", "advance distribution cursor") end
        if changed.rows_affected ~= 1 then return failure("CONFLICT", "distribution cursor changed during checkpoint") end
        return transaction.success({source_owner = source, feed = feed,
            destination_node = destination, cursor = next_cursor}, false)
    end)
end

function M.close(store: Store): boolean
    if store.closed then return true end
    store.closed = true
    return store.db:release() == true
end

return M
