-- MIT. Write and read transactions over an owned SQLite store. A busy
-- database retries the whole write after rollback; nothing waits while
-- holding one. SQLite serializes writers on the resource's single
-- connection. The label names the store in failures.
local sql = require("sql")
local sqlerrors = require("sqlerrors")
local time = require("time")
local M = {}
type Result = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean, commit: boolean?}
type Body = (sql.Transaction) -> Result
M.MAX_ATTEMPTS = 5
M.BACKOFF_MS = 20
function M.busy(err: unknown): boolean
    local text = string.lower(sqlerrors.describe(err))
    return text:find("locked", 1, true) ~= nil or text:find("busy", 1, true) ~= nil
end
function M.storage_failure(message: string): Result
    return {ok = false, code = "BUSY", message = message, replayed = false}
end
function M.failure(code: string, message: string, value: unknown?): Result
    return {ok = false, code = code, message = message, value = value, replayed = false}
end
-- The native adapter reads SQLite codes from the retained Go error chain.
-- Keep that text intact while adding the operation which failed.
function M.error_message(action: string, err: unknown): string
    return action .. ": " .. sqlerrors.describe(err or "no reason given")
end
function M.sql_failure(err: unknown, action: string): Result
    return M.failure(M.busy(err) and "BUSY" or "INTERNAL", M.error_message(action, err))
end
function M.release(db: sql.DB, label: string, result: Result): Result
    local released, err = db:release()
    if released == true and not err then return result end
    local message = M.error_message("close " .. label .. " database", err)
    if not result.ok then message = tostring(result.message) .. "; " .. message end
    return M.failure("INTERNAL", message, result.value)
end
local function rollback(tx: sql.Transaction, label: string, result: Result): Result
    local rolled_back, err = tx:rollback()
    if rolled_back == true and not err then return result end
    local message = M.error_message("rollback " .. label .. " transaction", err)
    if not result.ok then message = tostring(result.message) .. "; " .. message end
    -- A failed rollback is never safe to retry.
    return M.failure("INTERNAL", message, result.value)
end
function M.success(value: unknown, replayed: boolean): Result
    return {ok = true, value = value, replayed = replayed}
end
-- A refusal is a failed operation whose side effects still commit: what it
-- observed on the way to refusing, such as a deadline it enforced, is durable.
function M.refusal(code: string, message: string, value: unknown): Result
    return {ok = false, code = code, message = message, value = value, replayed = false, commit = true}
end
-- Runs body inside one transaction. A success commits, a refusal commits
-- and still reports its failure, and every other failure rolls back.
function M.write(db: sql.DB, label: string, body: Body): Result
    local last: Result = M.storage_failure(label .. " database is busy")
    for attempt = 1, M.MAX_ATTEMPTS do
        local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
        if not tx then
            last = M.sql_failure(begin_err, "begin " .. label .. " transaction")
            if last.code ~= "BUSY" then return last end
        else
            local result = body(tx)
            if result.ok or result.commit then
                local committed, commit_err = tx:commit()
                if committed == true and not commit_err then return result end
                last = rollback(tx, label, M.sql_failure(commit_err, "commit " .. label .. " transaction"))
                if last.code ~= "BUSY" then return last end
            else
                last = rollback(tx, label, result)
                if last.code ~= "BUSY" then return last end
            end
        end
        if attempt < M.MAX_ATTEMPTS then time.sleep(tostring(M.BACKOFF_MS * attempt) .. "ms") end
    end
    return last
end
-- Runs body inside a read-only transaction so several reads share a snapshot.
function M.read(db: sql.DB, label: string, body: Body): Result
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE, read_only = true})
    if not tx then
        return M.sql_failure(begin_err, "begin " .. label .. " read")
    end
    local result = body(tx)
    return rollback(tx, label, result)
end
return M
