-- MIT. The node's application test runs: the request its tests tool makes, the
-- bounds a run keeps within and the reply envelope. The runner service and the
-- facade that authorizes callers share these.
local bounds = require("bounds")

local M = {}

-- The runner service holds NAME and takes WAKE messages as hints that a run
-- waits in the node database; a message carries nothing the runner trusts.
M.NAME = "bee.node.tests"
M.WAKE = "bee.node.tests.wake"
-- UPDATE prefixes the topic one run receives its tests' case events on.
M.UPDATE = "bee.node.tests.update."
M.DEFAULT_TIMEOUT = "30s"
M.MAX_TESTS = 64
M.MAX_CASES = 512
M.MAX_ERROR_BYTES = 2048
M.MAX_RUNS = 16
M.MAX_ACTIVE = 4

type Object = {[string]: unknown}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, value: unknown, error: Fault?}
type Request = {operation: string, application: string?, filter: string?, run_id: string?}

function M.fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end

function M.succeed(value: unknown): Reply
    return {ok = true, value = value, error = nil}
end

-- overlay_of names the overlay an application argument refers to: an
-- application definition id app.<overlay>:<name> or the overlay id itself.
function M.overlay_of(application: string): string
    local namespace = application:match("^([^:]+):")
    if namespace then return namespace:match("^app%.([^.]+)$") or "" end
    return application
end

-- truncate bounds one error text and reports whether it was cut.
function M.truncate(text: string): (string, boolean)
    if #text <= M.MAX_ERROR_BYTES then return text, false end
    return text:sub(1, M.MAX_ERROR_BYTES), true
end

-- decode reads a tests tool request: list and run name an application and may
-- narrow its tests by a substring of their ids, status names a run.
function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "request must be an object" end
    local unknown_field = bounds.fields(value, {"operation", "application", "filter", "run_id"})
    if unknown_field then return nil, unknown_field end
    local operation = bounds.member(value.operation, {"list", "run", "status"})
    if not operation then return nil, "operation must be list, run or status" end
    local request: Request = {operation = operation, application = nil, filter = nil, run_id = nil}
    if operation == "status" then
        if value.application ~= nil or value.filter ~= nil then return nil, "status takes only run_id" end
        request.run_id = bounds.id(value.run_id)
        if not request.run_id then return nil, "status needs a run_id" end
        return request, nil
    end
    if value.run_id ~= nil then return nil, "only status takes a run_id" end
    request.application = bounds.id(value.application)
    if not request.application then return nil, operation .. " needs an application" end
    if value.filter ~= nil then
        request.filter = bounds.text(value.filter, 160)
        if not request.filter or request.filter == "" then return nil, "filter must be a short non-empty text" end
    end
    return request, nil
end

return M
