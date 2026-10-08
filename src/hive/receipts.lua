-- MIT
local json = require("json")
local database = require("database")
local transaction = require("transaction")
local canonical = require("canonical")
local protocol = require("protocol")
local sql = require("sql")
local M = {}
M.MAX_RECEIPTS = 4096
function M.claim(key: string, fingerprint: string): (boolean, protocol.Reply?, string?)
    local db, err = database.open()
    if not db then return false, nil, err end
    local result = transaction.write(db, "Hive receipts", function(tx: sql.Transaction): transaction.Result
        local rows, read_error = tx:query("SELECT fingerprint, reply_json FROM bee_hive_receipts WHERE receipt_key = ?", {key})
        if not rows then return transaction.sql_failure(read_error, "read Hive receipt") end
        if rows[1] then
            local row = rows[1]
            if row.fingerprint ~= fingerprint then return transaction.failure("CONFLICT", "idempotency key names different arguments or operation revision") end
            if row.reply_json == nil then return transaction.failure("UNKNOWN", "mutation is pending or interrupted; outcome unknown") end
            local decoded = json.decode(tostring(row.reply_json))
            local reply, reply_error = protocol.decode_reply(decoded, "stored", "stored")
            if not reply then return transaction.failure("INVALID", "invalid stored Hive receipt: " .. tostring(reply_error)) end
            return transaction.success(reply, true)
        end
        local counted, count_error = tx:query("SELECT COUNT(*) AS count FROM bee_hive_receipts")
        if not counted then return transaction.sql_failure(count_error, "count Hive receipts") end
        if (tonumber(counted[1].count) or M.MAX_RECEIPTS) >= M.MAX_RECEIPTS then return transaction.failure("FULL", "Hive mutation receipt capacity is full") end
        local _, insert_error = tx:execute("INSERT INTO bee_hive_receipts (receipt_key, fingerprint) VALUES (?, ?)", {key, fingerprint})
        if insert_error then return transaction.sql_failure(insert_error, "claim Hive receipt") end
        return transaction.success(nil, false)
    end)
    result = transaction.release(db, "Hive receipts", result)
    if not result.ok then return false, nil, result.message end
    if result.replayed then
        return false, result.value :: protocol.Reply, nil
    end
    return true, nil, nil
end
function M.complete(key: string, reply: protocol.Reply): (boolean, string?)
    local encoded, err = canonical.encode(reply, protocol.MAX_BYTES)
    if not encoded then return false, err end
    local db, open_error = database.open()
    if not db then return false, open_error end
    local result = transaction.write(db, "Hive receipts", function(tx: sql.Transaction): transaction.Result
        local _, write_error = tx:execute("UPDATE bee_hive_receipts SET reply_json = ? WHERE receipt_key = ? AND reply_json IS NULL", {encoded, key})
        if write_error then return transaction.sql_failure(write_error, "complete Hive receipt") end
        return transaction.success(nil, false)
    end)
    result = transaction.release(db, "Hive receipts", result)
    return result.ok, result.message
end
return M
