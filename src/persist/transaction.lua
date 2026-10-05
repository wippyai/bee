-- MIT. Write and read transactions over the node database. SQLite serializes
-- writers on the resource's single connection; a busy database fails the
-- write with BUSY after rollback. The label names the store in failures.
local sql = require("sql")
local M = {}
type Result = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean, commit: boolean?}
type Body = (sql.Transaction) -> Result
function M.busy(err: unknown): boolean
    if err == nil then return false end
    local details: unknown = errors.wrap(err, "SQLite classification"):details()
    if type(details) ~= "table" then return false end
    return details.sqlite_code == 5 or details.sqlite_code == 6
end
function M.storage_failure(message: string): Result
    return {ok = false, code = "BUSY", message = message, replayed = false}
end
function M.failure(code: string, message: string, value: unknown?): Result
    return {ok = false, code = code, message = message, value = value, replayed = false}
end
-- Keep the native error text intact while adding the failed operation.
function M.error_message(action: string, err: unknown): string
    return action .. ": " .. tostring(err or "no reason given")
end
function M.sql_failure(err: unknown, action: string): Result
    return M.failure(M.busy(err) and "BUSY" or "INTERNAL", M.error_message(action, err))
end
-- release closes db after an operation and keeps its result; a failed close
-- is reported with the operation's own failure.
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
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return M.sql_failure(begin_err, "begin " .. label .. " transaction") end
    local result = body(tx)
    if not result.ok and not result.commit then return rollback(tx, label, result) end
    local committed, commit_err = tx:commit()
    if committed == true and not commit_err then return result end
    return rollback(tx, label, M.sql_failure(commit_err, "commit " .. label .. " transaction"))
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
