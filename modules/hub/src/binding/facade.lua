-- MIT. Authorize the public operation before entering the fixed Hub scope.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local catalog = require("catalog")
local inspection = require("inspection")
local plan = require("plan")
local preview = require("preview")
local publishing = require("publishing")
local transaction = require("transaction")
local hub_result = require("hub_result")
type Result = transaction.Result
local BACKEND = "bee.hub.binding:backend"
local SCOPE = "bee.hub.security:execution_scope"
local function handle(raw: unknown): Result
    local value = bounds.object(raw)
    if not value then return transaction.failure("INVALID", "Hub request must be an object") end
    local extra = bounds.fields(value, {"operation", "request", "expected_digest"})
    if extra then return transaction.failure("INVALID", extra) end
    local operation = bounds.member(value.operation, {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "installed_source", "updates", "plan", "apply", "status", "publish_request", "publish_apply"})
    if not operation then return transaction.failure("INVALID", "unknown Hub operation") end
    local resource = "catalog"
    local self_update = false
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
        local request, problem = inspection.decode(value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid inspection request") end
        resource = request.component
    elseif operation == "installed_source" then
        local supplied = bounds.object(value.request)
        if not supplied then return transaction.failure("INVALID", "installed source requires a component and version") end
        local request, problem = inspection.decode({component = supplied.component, version = supplied.version})
        if not request then return transaction.failure("INVALID", problem or "invalid installed source request") end
        resource = request.component
    elseif operation == "plan" or operation == "apply" then
        local request, problem = plan.decode(value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid package request") end
        resource = request.component
        self_update = request.component == "bee/bee"
    elseif operation == "publish_request" then
        local request, problem = publishing.decode(value.request)
        if not request then return transaction.failure("INVALID", problem or "invalid publication request") end
        resource = request.component
    elseif operation == "publish_apply" then
        local supplied = bounds.object(value.request)
        local digest = supplied and value.expected_digest or nil
        local component = supplied and bounds.line(supplied.component, 160) or nil
        if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$")
            or not component or not component:match("^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$") then
            return transaction.failure("INVALID", "publication apply names a component and its plan digest")
        end
        resource = component
    elseif operation == "status" then
        if value.expected_digest ~= nil then
            if value.request ~= nil then return transaction.failure("INVALID", "receipt lookup takes no request body") end
        else
            local request = bounds.object(value.request == nil and {} or value.request)
            if not request or bounds.fields(request, {"page"}) then return transaction.failure("INVALID", "invalid operation history request") end
            if request.page ~= nil then
                local decoded_page = bounds.count(request.page)
                if not decoded_page or decoded_page < 1 or decoded_page > 10000 then
                    return transaction.failure("INVALID", "invalid operation history page")
                end
            end
        end
    elseif operation == "updates" then
        resource = "updates"
    elseif value.request ~= nil then return transaction.failure("INVALID", "operation takes no request body") end
    if operation == "apply" or operation == "publish_apply"
        or (operation == "status" and value.expected_digest ~= nil) then
        local digest = value.expected_digest
        if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return transaction.failure("INVALID", "operation requires a plan digest")
        end
    elseif value.expected_digest ~= nil then return transaction.failure("INVALID", "operation takes no plan digest") end
    -- Planning resolves and verifies the complete dependency closure but does
    -- not publish registry state. It can reveal other installed roots, so a
    -- scoped caller also needs inventory/catalog read authority. Only apply
    -- crosses the management boundary. Publication staging seals the pack on
    -- the host and publication applies it, so both need management
    -- authority.
    local action = "bee.hub.read"
    if operation == "apply" or operation == "publish_request" or operation == "publish_apply" then
        action = "bee.hub.manage"
    end
    if not security.actor() or not security.can(action, resource) then return transaction.failure("DENIED", "Hub operation is not authorized") end
    if operation == "plan" and not security.can("bee.hub.read", "catalog") then
        return transaction.failure("DENIED", "Hub plan inventory is not authorized")
    end
    if self_update and not security.can("bee.hub.self_update", "bee/bee") then
        return transaction.failure("DENIED", "Bee self-update is not authorized")
    end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return transaction.failure("UNAVAILABLE", tostring(scope_error)) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return transaction.failure("DENIED", tostring(executor_error)) end
    local result, call_error = executor:call(BACKEND, {operation = operation, request = value.request or {}, expected_digest = value.expected_digest})
    if call_error then return transaction.failure("UNCERTAIN", tostring(call_error)) end
    return hub_result.decode(result)
end
return {handle = handle}
