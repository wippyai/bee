-- MIT. The shared edge of every authority method: authenticate, open the
-- linked store, run one operation, release, and shape the reply.
local sql = require("sql")
local process = require("process")
local resources = require("resources")
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
M.WAITER_NAME = "bee.threads.waiter"
M.TOPIC_COMMITTED = "bee.threads.committed"
-- After a commit, the waiter learns that the thread moved. Missing waiter,
-- no wakeups: waits still end at their deadline with a final check.
local function notify(request: unknown)
    if type(request) ~= "table" or type(request.thread_id) ~= "string" then return end
    local pid, err = process.registry.lookup(M.WAITER_NAME)
    if err or not pid then return end
    process.send(tostring(pid), M.TOPIC_COMMITTED, {version = 1, thread_id = request.thread_id})
end
function M.run(operation: Operation, request: unknown, mutates: boolean?): types.Reply
    local actor = access.actor()
    if not actor then return fault("DENIED", "caller is not authenticated") end
    local resource, resource_error = resources.database()
    if not resource then return fault("UNLINKED_RESOURCE", resource_error or "thread database reference is not linked") end
    local db, open_error = database.open(resource)
    if not db then
        local message = open_error or "thread database unavailable"
        if message:find("migration", 1, true) or message:find("schema", 1, true) then return fault("SCHEMA_MISMATCH", message) end
        if message == "open thread database" then return fault("UNLINKED_RESOURCE", message) end
        return fault("INTERNAL", message)
    end
    local result = operation(db, actor, request)
    db:release()
    if mutates and result.ok and not result.replayed then notify(request) end
    return M.reply(result)
end
return M
