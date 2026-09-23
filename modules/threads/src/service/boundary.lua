-- MIT. The shared edge of every authority method: authenticate, open the
-- linked store, run one operation, release, and shape the reply.
local sql = require("sql")
local process = require("process")
local resources = require("resources")
local database = require("database")
local transaction = require("transaction")
local types = require("types")
local access = require("access")
local notices = require("notices")
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
function M.wake(thread_id: string)
    local pid, err = process.registry.lookup(M.WAITER_NAME)
    if err or not pid then return end
    process.send(tostring(pid), M.TOPIC_COMMITTED, {version = 1, thread_id = thread_id})
end
local function notify(request: unknown)
    if type(request) ~= "table" or type(request.thread_id) ~= "string" then return end
    M.wake(request.thread_id)
end
-- A commit on a thread may end the turn or attempt a notice watches. The
-- notices it settles land on their watchers' threads, whose waiters learn
-- of them too. A pass that cannot settle now leaves its notices pending for
-- the next commit on the thread and the owner's sweep.
local function settle_notices(db: sql.DB, request: unknown)
    if type(request) ~= "table" or type(request.thread_id) ~= "string" then return end
    local woken = notices.fire(db, request.thread_id)
    for _, thread_id in ipairs(woken or {}) do M.wake(thread_id) end
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
    local committed = mutates and result.ok and not result.replayed
    if committed then settle_notices(db, request) end
    db:release()
    if committed then notify(request) end
    return M.reply(result)
end
return M
