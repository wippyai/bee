-- MIT. The shared edge of every authority method: authenticate, open the
-- node database, run one operation, release, and shape the reply.
local sql = require("sql")
local database = require("database")
local transaction = require("transaction")
local types = require("types")
local access = require("access")
type Operation = (sql.DB, string, unknown) -> transaction.Result
local M = {}
local function fault(code: string, message: string): types.Reply
    return {ok = false, error = {code = code, message = message, retryable = code == "BUSY"}, replayed = false}
end
function M.reply(result: transaction.Result): types.Reply
    if result.ok then return {ok = true, value = result.value, replayed = result.replayed} end
    return fault(result.code or "INTERNAL", result.message or "thread operation failed")
end
function M.run(operation: Operation, request: unknown): types.Reply
    local actor = access.actor()
    if not actor then return fault("DENIED", "caller is not authenticated") end
    local db, open_error = database.open()
    if not db then return fault("UNAVAILABLE", open_error or "thread database unavailable") end
    local result = operation(db, actor, request)
    db:release()
    return M.reply(result)
end
return M
