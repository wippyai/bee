-- MIT. The node's application test runs: the request its tests tool makes, the
-- bounds a run keeps within and the reply envelope. The runner service and the
-- facade that authorizes callers share these.
local bounds = require("bounds")
local app_tool_request = require("app_tool_request")

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
type Request = {operation: string, application: string?, filter: string?, run_id: string?, node: string?, idempotency_key: string?}
type Hive = {caller: string, node: string, service: string, operation: string}
type Planned = {id: string, suite: string, timeout: string, hive: Hive?}
type Backend = {operation: string, workspace_id: string, actor_id: string, application: string?, owned: {[string]: boolean},
    filter: string?, run_id: string?}
M.Hive = Hive
M.Planned = Planned
M.Backend = Backend

function M.fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end

function M.succeed(value: unknown): Reply
    return {ok = true, value = value, error = nil}
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
    local unknown_field = bounds.fields(value, {"operation", "application", "filter", "run_id", "node", "idempotency_key"})
    if unknown_field then return nil, unknown_field end
    local operation = bounds.member(value.operation, {"list", "run", "status"})
    if not operation then return nil, "operation must be list, run or status" end
    local node, node_error = app_tool_request.node(value.node)
    if node_error then return nil, node_error end
    local key = value.idempotency_key == nil and nil or bounds.line(value.idempotency_key, 128)
    if value.idempotency_key ~= nil and (operation ~= "run" or not key) then return nil, "only run takes a bounded idempotency key" end
    local request: Request = {operation = operation, application = nil, filter = nil, run_id = nil, node = node, idempotency_key = key}
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

local function hive_of(raw: unknown): (Hive?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "stored Hive fields are invalid" end
    local caller, node = bounds.id(value.caller), bounds.id(value.node)
    local service, operation = bounds.id(value.service), bounds.id(value.operation)
    if bounds.fields(value, {"caller", "node", "service", "operation"}) or not (caller and node and service and operation) then
        return nil, "stored Hive fields are invalid"
    end
    return {caller = caller, node = node, service = service, operation = operation}, nil
end

-- plan reads a stored plan: a dense list of at most MAX_TESTS planned tests.
function M.plan(raw: unknown): ({Planned}?, string?)
    local rows, rows_error = bounds.dense_list(raw, M.MAX_TESTS, "stored plan")
    if not rows then return nil, tostring(rows_error) end
    local planned: {Planned} = {}
    for _, item in ipairs(rows) do
        local value = bounds.object(item)
        local id = value and bounds.id(value.id)
        local suite = value and bounds.line(value.suite, 160)
        local timeout = value and bounds.line(value.timeout, 32)
        if not value or bounds.fields(value, {"id", "suite", "timeout", "hive"}) or not (id and suite and timeout) then
            return nil, "stored plan entry is invalid"
        end
        local hive: Hive? = nil
        if value.hive ~= nil then
            local decoded, hive_error = hive_of(value.hive)
            if not decoded then return nil, hive_error end
            hive = decoded
        end
        planned[#planned + 1] = {id = id, suite = suite, timeout = timeout, hive = hive}
    end
    return planned, nil
end

-- backend_request reads the request the facade hands the test backend.
function M.backend_request(raw: unknown): (Backend?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "test backend request must be an object" end
    local unknown_field = bounds.fields(value, {"operation", "workspace_id", "actor_id", "application", "owned", "filter", "run_id"})
    if unknown_field then return nil, unknown_field end
    local operation = bounds.member(value.operation, {"list", "run", "status"})
    local workspace_id, actor_id = bounds.id(value.workspace_id), bounds.id(value.actor_id)
    if not operation or not workspace_id or not actor_id then return nil, "test backend request names no operation, workspace or actor" end
    local owned: {[string]: boolean} = {}
    if value.owned ~= nil then
        local listed = bounds.object(value.owned)
        if not listed then return nil, "owned overlays must be an object" end
        for id, flag in pairs(listed) do
            if not bounds.id(id) or flag ~= true then return nil, "owned overlays must map identifiers to true" end
            owned[id] = true
        end
    end
    local request: Backend = {operation = operation, workspace_id = workspace_id, actor_id = actor_id, application = nil,
        owned = owned, filter = nil, run_id = nil}
    if operation == "status" then
        request.run_id = bounds.id(value.run_id)
        if not request.run_id or value.application ~= nil or value.filter ~= nil then return nil, "status takes only a run_id" end
        return request, nil
    end
    request.application = bounds.id(value.application)
    if not request.application or value.run_id ~= nil then return nil, operation .. " takes an application and no run_id" end
    if value.filter ~= nil then
        request.filter = bounds.text(value.filter, 160)
        if not request.filter or request.filter == "" then return nil, "filter must be a short non-empty text" end
    end
    return request, nil
end

return M
