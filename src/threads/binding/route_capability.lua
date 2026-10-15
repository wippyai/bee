local security = require("security")
local json = require("json")
local bounds = require("bounds")
local database = require("database")
local journal = require("journal")
local transaction = require("transaction")
local boundary = require("boundary")
local types = require("types")
local function handle(raw: unknown): types.Reply
    local request = bounds.object(raw)
    local workspace = request and bounds.id(request.workspace_id)
    local session = request and bounds.id(request.session)
    if not request or not workspace or not session or bounds.fields(request, {"workspace_id", "session"}) then
        return {ok = false, error = {code = "INVALID_ARGUMENT", message = "session and workspace are required", retryable = false}, replayed = false}
    end
    if not security.can("bee.threads.route_capability", workspace) then
        return {ok = false, error = {code = "DENIED", message = "session route is not admitted", retryable = false}, replayed = false}
    end
    local db, err = database.open()
    if not db then return {ok = false, error = {code = "UNAVAILABLE", message = err or "session store unavailable", retryable = false}, replayed = false} end
    local result = transaction.read(db, function(tx: sql.Transaction): transaction.Result
        local row, problem = journal.session(tx, session, workspace)
        if problem then return transaction.failure("INTERNAL", problem) end
        if not row then return transaction.failure("NOT_FOUND", "session is unavailable") end
        local route = bounds.object(json.decode(row.route_json))
        local provider = route and bounds.id(route.provider)
        if not provider then return transaction.failure("UNAVAILABLE", "session route provider is unavailable") end
        return transaction.success({provider = provider}, false)
    end)
    db:release()
    return boundary.reply(result)
end
return {handle = handle}
