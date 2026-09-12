-- MIT. Authorize the public operation before entering the fixed Hub scope.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local catalog = require("catalog")
local inspect = require("inspect")
local plan = require("plan")
local preview = require("preview")
local transaction = require("transaction")
type Result = transaction.Result
local BACKEND = "bee.hub:backend"
local SCOPE = "bee.hub:execution_scope"
local function handle(raw: unknown): Result
    local value = bounds.object(raw)
    if not value then return transaction.failure("INVALID", "Hub request must be an object") end
    local extra = bounds.fields(value, {"operation", "request", "expected_digest"})
    if extra then return transaction.failure("INVALID", extra) end
    local operation = bounds.member(value.operation, {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "plan", "apply", "status"})
    if not operation then return transaction.failure("INVALID", "unknown Hub operation") end
    local resource = "catalog"
    if operation == "catalog" then
        local request, problem = catalog.decode(value.request or {})
        if not request then return transaction.failure("INVALID", problem or "invalid catalog request") end
    elseif operation == "details" then
        local request, problem = catalog.decode_detail(value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid details request") end
        resource = request.component
    elseif operation == "state" or operation == "files" or operation == "read_file" then
        local request, problem = preview.decode(operation, value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid package read") end
        resource = request.component
    elseif operation == "inspect" then
        local request, problem = inspect.decode(value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid inspection request") end
        resource = request.component
    elseif operation == "plan" or operation == "apply" then
        local request, problem = plan.decode(value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid package request") end
        resource = request.component
    elseif operation == "status" then
        if value.expected_digest ~= nil then
            if value.request ~= nil then return transaction.failure("INVALID", "receipt lookup takes no request body") end
        else
            local request = bounds.object(value.request == nil and {} or value.request)
            if not request or bounds.fields(request, {"page"}) then return transaction.failure("INVALID", "invalid operation history request") end
            local page = request.page == nil and 1 or bounds.count(request.page)
            if not page or page < 1 or page > 10000 then return transaction.failure("INVALID", "invalid operation history page") end
        end
    elseif value.request ~= nil then return transaction.failure("INVALID", "operation takes no request body") end
    if operation == "apply" or (operation == "status" and value.expected_digest ~= nil) then
        local digest = value.expected_digest
        if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return transaction.failure("INVALID", "operation requires a plan digest")
        end
    elseif value.expected_digest ~= nil then return transaction.failure("INVALID", "operation takes no plan digest") end
    local action = (operation == "plan" or operation == "apply") and "bee.hub.manage" or "bee.hub.read"
    if not security.actor() or not security.can(action, resource) then return transaction.failure("DENIED", "Hub operation is not authorized") end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return transaction.failure("UNAVAILABLE", tostring(scope_error)) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return transaction.failure("DENIED", tostring(executor_error)) end
    local result, call_error = executor:call(BACKEND, {operation = operation, request = value.request or {}, expected_digest = value.expected_digest})
    if call_error then return transaction.failure("UNCERTAIN", tostring(call_error)) end
    local reply = bounds.object(result)
    if not reply or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then
        return transaction.failure("UNCERTAIN", "invalid Hub backend reply")
    end
    local code: string? = nil
    local message: string? = nil
    if reply.code ~= nil then
        code = bounds.line(reply.code, 160)
        if not code then return transaction.failure("UNCERTAIN", "invalid Hub result code") end
    end
    if reply.message ~= nil then
        message = bounds.text(reply.message, 4096)
        if not message then return transaction.failure("UNCERTAIN", "invalid Hub result message") end
    end
    return {ok = reply.ok, replayed = reply.replayed, code = code, message = message, value = reply.value}
end
return {handle = handle}
