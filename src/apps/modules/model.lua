-- MIT. Modules is a presentation model. It never calls Hub or the registry:
-- the application sends these intents to bee.hub:call and folds its typed
-- transaction replies back here.
local json = require("json")
local canonical = require("canonical")
local text = require("text")
local M = {}

M.MAX_TEXT = 512
M.MAX_PARAMETERS = 128
M.MAX_ITEMS = 100
M.HUB = "bee.hub:call"

type Object = {[string]: unknown}
type Reply = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Intent = {operation: string, request: Object?, expected_digest: string?}
type Phase = "catalog" | "installed" | "details" | "operations" | "plan" | "confirm" | "result"
type Item = {component: string, title: string, description: string, latest_version: string}
type Version = {version: string, yanked: boolean}
type Detail = {component: string, title: string, description: string, readme: string, versions: {Version}, page: integer, total_versions: integer}
type Module = {component: string, version: string, source: string, direct: boolean, used_by: {string}}
type Parameter = {name: string, value: unknown, json: string}
type Plan = {digest: string, ready: boolean, base_revision: integer, modules: {Object}, missing: {string}, migrations: {Object}, starts: {string}, capabilities: {string}}
type Result = {ok: boolean, code: string, message: string, replayed: boolean, state: string}
type Operation = {digest: string, component: string, action: string, state: string, message: string, baseline_revision: integer, request: Object?, migration_work: {Object}}
type Recovery = {digest: string, request: Object, operation: Operation}
type State = {
    phase: Phase, keyword: string, query: string, page: integer, catalog: {Item}, total: integer,
    installed: {Module}, selected: string?, detail: Detail?, selected_version: string?,
    action: string, policy: string, parameters: {Parameter}, plan: Plan?, result: Result?, notice: string,
    operation_page: integer, operation_total: integer, operation_page_size: integer, operation_detail_offset: integer, operations: {Operation}, selected_operation: Operation?, recovery: Recovery?,
}

function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.MAX_TEXT)
end

local function readme(value: unknown): string
    if type(value) ~= "string" then return "" end
    local lines: {string} = {}
    local content = value:sub(1, 16384)
    content = content .. "\n"
    for line in string.gmatch(content, "([^\n]*)\n") do
        lines[#lines + 1] = M.text(line, 16384)
    end
    return table.concat(lines, "\n")
end

local function object(value: unknown): Object
    if type(value) == "table" then return value :: Object end
    return {}
end

-- Replies are owned by the transport. Keep an immutable recovery request in
-- the model so later catalog, parameter, or selection changes cannot rewrite
-- what a recovery confirmation will publish.
local function clone(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(value :: {[unknown]: unknown}) do result[clone(key)] = clone(item) end
    return result
end

local function integer(value: unknown): integer
    local number = tonumber(value)
    if not number or number ~= number then return 0 end
    return math.floor(number)
end

local function component(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 160 or not value:match("^[%w_.-]+/[%w_.-]+$") then return nil end
    return value
end

local function version(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 128 or value:find("%c") then return nil end
    return value
end

local function digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function operation_request(raw: unknown, action: string, owner: string): Object?
    if type(raw) ~= "table" then return nil end
    local value = raw :: Object
    if value.action ~= action or value.component ~= owner then return nil end
    local policy = type(value.migration_policy) == "string" and value.migration_policy or ""
    local valid_policy = (action == "uninstall" and (policy == "block" or policy == "leave" or policy == "down"))
        or (action ~= "uninstall" and (policy == "none" or policy == "up"))
    if not valid_policy then return nil end
    local result: Object = {action = action, component = owner, migration_policy = policy}
    if action == "uninstall" then
        if value.version ~= nil or value.parameters ~= nil then return nil end
        return result
    end
    local selected_version = version(value.version)
    if not selected_version or type(value.parameters) ~= "table" then return nil end
    local parameters: {Object} = {}
    for index, raw_parameter in ipairs(value.parameters :: {unknown}) do
        if index > M.MAX_PARAMETERS then return nil end
        local parameter = object(raw_parameter)
        local name = type(parameter.name) == "string" and parameter.name or ""
        if name == "" or #name > 256 or not name:match("^[^:%s]+:[^:%s]+$") or parameter.value == nil then return nil end
        parameters[index] = {name = name, value = clone(parameter.value)}
    end
    result.version, result.parameters = selected_version, parameters
    return result
end

local function migration_rows(raw: unknown): {Object}
    local work = object(raw)
    local rows: {Object} = {}
    if type(work.rows) ~= "table" then return rows end
    for index, raw_row in ipairs(work.rows :: {unknown}) do
        if index > M.MAX_ITEMS then break end
        local row = object(raw_row)
        local id, target, module, status = M.text(row.id, 256), M.text(row.target_db, 256), M.text(row.module, 160), M.text(row.status, 32)
        if id ~= "" and target ~= "" and module ~= "" and (status == "applied" or status == "reverted" or status == "skipped") then
            local decoded: Object = {id = id, target_db = target, module = module, status = status}
            if row.reason ~= nil then decoded.reason = M.text(row.reason, 160) end
            rows[#rows + 1] = decoded
        end
    end
    return rows
end

local function reset_plan(state: State)
    state.plan, state.result, state.recovery, state.selected_operation = nil, nil, nil, nil
    if state.phase == "plan" or state.phase == "confirm" or state.phase == "result" then state.phase = state.detail and "details" or "catalog" end
end

function M.new(): State
    return {phase = "catalog", keyword = "bee", query = "", page = 1, catalog = {}, total = 0,
        installed = {}, selected = nil, detail = nil, selected_version = nil, action = "install", policy = "none",
        parameters = {}, plan = nil, result = nil, notice = "", operation_page = 1, operation_total = 0,
        operation_page_size = 25, operation_detail_offset = 0, operations = {}, selected_operation = nil, recovery = nil}
end

-- Presentation changes have no Hub side effect. Keep them here so clients do
-- not need to reach into the state record just to change panes.
function M.show(state: State, phase: Phase)
    if phase ~= "confirm" then state.recovery = nil end
    if phase ~= "operations" and phase ~= "confirm" then
        state.selected_operation, state.recovery = nil, nil
    end
    state.phase = phase
end

function M.catalog_intent(state: State): Intent
    local request: Object = {keyword = state.keyword, page = state.page}
    if state.query ~= "" then request.query = state.query end
    return {operation = "catalog", request = request}
end

function M.installed_intent(_: State): Intent return {operation = "installed"} end

function M.operation_history_intent(state: State): Intent
    return {operation = "status", request = {page = math.max(1, math.min(10000, state.operation_page))}}
end

function M.apply_history(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then
        state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "operation history unavailable"))
        return
    end
    local value = object(reply.value)
    if type(value.operations) ~= "table" then
        state.notice = "status reply did not include operation history"
        return
    end
    local operations: {Operation} = {}
    for index, raw in ipairs(value.operations :: {unknown}) do
        if index > M.MAX_ITEMS then break end
        local item = object(raw)
        local measured = digest(item.digest)
        local owner = component(item.component)
        local action = (item.action == "install" and "install") or (item.action == "update" and "update")
            or (item.action == "uninstall" and "uninstall") or nil
        local baseline = integer(item.baseline_revision)
        if measured and owner and action and baseline >= 0 then
            local op: Operation = {digest = measured, component = owner, action = action, state = M.text(item.state, 80),
                message = M.text(item.message, 512), baseline_revision = baseline, request = operation_request(item.request, action, owner),
                migration_work = migration_rows(item.migration_work)}
            operations[#operations + 1] = op
        end
    end
    table.sort(operations, function(a: Operation, b: Operation): boolean
        if a.baseline_revision ~= b.baseline_revision then return a.baseline_revision > b.baseline_revision end
        return a.digest > b.digest
    end)
    local page = integer(value.page)
    local total = integer(value.total)
    local page_size = integer(value.page_size)
    state.operations, state.operation_page = operations, math.max(1, page)
    state.operation_total, state.operation_page_size = math.max(0, total), page_size > 0 and math.min(100, page_size) or 25
    if state.selected_operation then
        local selected = state.selected_operation.digest
        state.selected_operation = nil
        for _, operation in ipairs(operations) do
            if operation.digest == selected then state.selected_operation = operation; break end
        end
    end
    if state.recovery and (not state.selected_operation or state.recovery.digest ~= state.selected_operation.digest
        or (state.selected_operation.state ~= "published" and state.selected_operation.state ~= "recovery_required")) then
        state.recovery = nil
    end
    state.phase, state.notice = "operations", ""
end

function M.select_operation(state: State, measured: string): (Operation?, string?)
    for _, operation in ipairs(state.operations) do
        if operation.digest == measured then
            state.selected_operation, state.phase, state.notice = operation, "operations", ""
            state.operation_detail_offset = 0
            return operation, nil
        end
    end
    state.selected_operation = nil
    return nil, "operation is not in the loaded history page"
end

function M.set_operation_detail_offset(state: State, offset: integer)
    state.operation_detail_offset = math.max(0, math.min(10000, math.floor(offset)))
end

function M.recover(state: State): string?
    local operation = state.selected_operation
    if not operation then return "select an operation first" end
    if operation.state ~= "published" and operation.state ~= "recovery_required" then
        return "only published or recovery-required operations can be recovered"
    end
    if not operation.request then return "this operation has no stored request for recovery" end
    local preserved = clone(operation.request)
    if type(preserved) ~= "table" then return "this operation has no stored request for recovery" end
    state.recovery = {digest = operation.digest, request = preserved :: Object, operation = operation}
    state.phase, state.notice = "confirm", ""
    return nil
end

function M.details_intent(state: State): Intent?
    if not state.selected then return nil end
    return {operation = "details", request = {component = state.selected, page = state.detail and state.detail.page or 1}}
end

function M.inspect_intent(state: State): Intent?
    if not state.selected or not state.selected_version then return nil end
    local parameters: {Object} = {}
    for index, parameter in ipairs(state.parameters) do parameters[index] = {name = parameter.name, value = parameter.value} end
    return {operation = "inspect", request = {component = state.selected, version = state.selected_version, parameters = parameters}}
end

function M.plan_intent(state: State): (Intent?, string?)
    if not state.selected then return nil, "select a package first" end
    if state.action ~= "uninstall" and not state.selected_version then return nil, "select an exact package version" end
    local parameters: {Object} = {}
    if state.action ~= "uninstall" then
        for index, parameter in ipairs(state.parameters) do parameters[index] = {name = parameter.name, value = parameter.value} end
    end
    local request: Object = {action = state.action, component = state.selected, migration_policy = state.policy}
    if state.action ~= "uninstall" then request.version, request.parameters = state.selected_version, parameters end
    return {operation = "plan", request = request}, nil
end

function M.confirm_intent(state: State): (Intent?, string?)
    if state.phase ~= "confirm" then return nil, "review confirmation before applying" end
    if state.recovery then
        local request = clone(state.recovery.request)
        if type(request) ~= "table" then return nil, "recovery request is unavailable" end
        return {operation = "apply", request = request :: Object, expected_digest = state.recovery.digest}, nil
    end
    local plan = state.plan
    if not plan then return nil, "prepare a plan first" end
    if not plan.ready then return nil, "fill every required package value before confirmation" end
    local intent, problem = M.plan_intent(state)
    if not intent then return nil, problem end
    return {operation = "apply", request = intent.request, expected_digest = plan.digest}, nil
end

function M.set_operation_page(state: State, page: integer)
    state.operation_page = math.max(1, math.min(10000, math.floor(page)))
end

function M.status_intent(state: State): Intent?
    if state.selected_operation then return {operation = "status", expected_digest = state.selected_operation.digest} end
    local plan = state.plan
    if not plan then return nil end
    return {operation = "status", expected_digest = plan.digest}
end

function M.set_keyword(state: State, value: unknown)
    local selected = M.text(value, 160)
    if selected ~= state.keyword then state.keyword, state.page = selected, 1; reset_plan(state) end
end

function M.set_query(state: State, value: unknown)
    local selected = M.text(value, 160)
    if selected ~= state.query then state.query, state.page = selected, 1; reset_plan(state) end
end

function M.set_page(state: State, page: integer)
    local selected = math.max(1, math.min(10000, math.floor(page)))
    if selected ~= state.page then state.page = selected; reset_plan(state) end
end

function M.select(state: State, name: string?)
    if name ~= state.selected then
        state.selected, state.detail, state.selected_version, state.parameters = name, nil, nil, {}
        state.action, state.policy = "install", "none"
        reset_plan(state)
    end
    if name then state.phase = "details" else state.phase = "catalog" end
end

function M.select_version(state: State, selected: string?)
    if selected ~= state.selected_version then state.selected_version = selected; reset_plan(state) end
end

function M.set_detail_page(state: State, page: integer)
    if state.detail then
        local selected = math.max(1, math.min(10000, math.floor(page)))
        if selected ~= state.detail.page then state.detail.page = selected; reset_plan(state) end
    end
end

function M.set_action(state: State, action: string)
    if action ~= "install" and action ~= "update" and action ~= "uninstall" then return end
    if action ~= state.action then
        state.action = action
        state.policy = action == "uninstall" and "block" or "none"
        reset_plan(state)
    end
end

function M.set_policy(state: State, policy: string)
    local uninstall = state.action == "uninstall"
    local valid = (uninstall and (policy == "block" or policy == "leave" or policy == "down"))
        or (not uninstall and (policy == "none" or policy == "up"))
    if valid and policy ~= state.policy then state.policy = policy; reset_plan(state) end
end

function M.set_parameter(state: State, name: unknown, encoded: unknown): string?
    local id = type(name) == "string" and name or nil
    if not id or #id == 0 or #id > 256 or not id:match("^[^:%s]+:[^:%s]+$") then return "parameter name must be a qualified identifier" end
    local source = M.text(encoded, 8192)
    if source == "" then return "parameter value must be JSON" end
    local value, problem = json.decode(source)
    if problem or value == nil then return "parameter value is not JSON" end
    local normalized, normalization_error = json.encode(value)
    if not normalized or normalization_error then return "parameter value cannot be represented" end
    for _, parameter in ipairs(state.parameters) do
        if parameter.name == id then
            parameter.value, parameter.json = value, normalized
            reset_plan(state)
            return nil
        end
    end
    if #state.parameters >= M.MAX_PARAMETERS then return "too many parameters" end
    state.parameters[#state.parameters + 1] = {name = id, value = value, json = normalized}
    table.sort(state.parameters, function(a: Parameter, b: Parameter): boolean return a.name < b.name end)
    reset_plan(state)
    return nil
end

function M.remove_parameter(state: State, name: string)
    for index, parameter in ipairs(state.parameters) do
        if parameter.name == name then table.remove(state.parameters, index); reset_plan(state); return end
    end
end

function M.apply_catalog(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "catalog unavailable")); return end
    local value = object(reply.value)
    local rows: {Item} = {}
    if type(value.items) == "table" then
        for _, raw in ipairs(value.items :: {unknown}) do
            local item = object(raw)
            local name = component(item.component)
            if name and #rows < M.MAX_ITEMS then rows[#rows + 1] = {component = name, title = M.text(item.title, 160),
                description = M.text(item.description, 512), latest_version = M.text(item.latest_version, 128)} end
        end
    end
    state.catalog, state.total, state.phase, state.notice = rows, integer(value.total), "catalog", ""
end

function M.apply_installed(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "installed modules unavailable")); return end
    local value, rows = object(reply.value), {}
    if type(value.modules) == "table" then
        for _, raw in ipairs(value.modules :: {unknown}) do
            local item = object(raw)
            local name = component(item.component)
            if name and #rows < M.MAX_ITEMS then
                local used: {string} = {}
                if type(item.used_by) == "table" then for _, owner in ipairs(item.used_by :: {unknown}) do used[#used + 1] = M.text(owner, 160) end end
                rows[#rows + 1] = {component = name, version = M.text(item.version, 128), source = M.text(item.source, 80), direct = item.direct == true, used_by = used}
            end
        end
    end
    state.installed, state.phase, state.notice = rows, "installed", ""
end

function M.apply_details(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "package details unavailable")); return end
    local value, name = object(reply.value), component(object(reply.value).component)
    if not name or name ~= state.selected then state.notice = "details did not match the selected package"; return end
    local versions: {Version} = {}
    if type(value.versions) == "table" then
        for _, raw in ipairs(value.versions :: {unknown}) do
            local item = object(raw)
            local selected = version(item.version)
            if selected then versions[#versions + 1] = {version = selected, yanked = item.yanked == true} end
        end
    end
    state.detail = {component = name, title = M.text(value.title, 160), description = M.text(value.description, 512),
        readme = readme(value.readme), versions = versions, page = math.max(1, integer(value.page)), total_versions = integer(value.total_versions)}
    if not state.selected_version then for _, item in ipairs(versions) do if not item.yanked then state.selected_version = item.version; break end end end
    state.phase, state.notice = "details", ""
end

local function matches_request(state: State, raw: unknown): boolean
    local intent = M.plan_intent(state)
    if not intent or not intent.request then return false end
    local expected, actual = intent.request, object(raw)
    if expected.action ~= actual.action or expected.component ~= actual.component
        or expected.migration_policy ~= actual.migration_policy then return false end
    -- The public uninstall request omits version/parameters. The measured
    -- backend plan returns their normalized empty values.
    if expected.action == "uninstall" then
        return actual.version == "" and type(actual.parameters) == "table" and next(actual.parameters) == nil
    end
    if expected.version ~= actual.version then return false end
    local expected_parameters = expected.parameters
    local actual_parameters = actual.parameters
    if type(expected_parameters) ~= "table" and type(actual_parameters) ~= "table" then return true end
    if type(expected_parameters) ~= "table" or type(actual_parameters) ~= "table" or #expected_parameters ~= #actual_parameters then return false end
    for index, expected_parameter in ipairs(expected_parameters :: {unknown}) do
        local left, right = object(expected_parameter), object((actual_parameters :: {unknown})[index])
        local left_value, right_value = canonical.encode(left.value), canonical.encode(right.value)
        if left.name ~= right.name or not left_value or not right_value or left_value ~= right_value then return false end
    end
    return true
end

function M.apply_plan(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.plan = nil; state.phase = "plan"; state.notice = M.text((reply.code or "INVALID") .. ": " .. (reply.message or "cannot prepare plan")); return end
    local value, digest = object(reply.value), object(reply.value).digest
    if type(digest) ~= "string" or #digest ~= 64 then state.notice = "Hub returned an unmeasured plan"; return end
    if not matches_request(state, value.request) then state.notice = "plan belongs to an earlier package selection; ignored"; return end
    local missing: {string}, modules: {Object}, migrations: {Object}, starts: {string}, capabilities: {string} = {}, {}, {}, {}, {}
    if type(value.missing) == "table" then for _, item in ipairs(value.missing :: {unknown}) do missing[#missing + 1] = M.text(item, 160) end end
    if type(value.modules) == "table" then for _, item in ipairs(value.modules :: {unknown}) do modules[#modules + 1] = object(item) end end
    if type(value.migrations) == "table" then for _, item in ipairs(value.migrations :: {unknown}) do migrations[#migrations + 1] = object(item) end end
    if type(value.starts) == "table" then for _, item in ipairs(value.starts :: {unknown}) do starts[#starts + 1] = M.text(item, 160) end end
    if type(value.capabilities) == "table" then for _, item in ipairs(value.capabilities :: {unknown}) do capabilities[#capabilities + 1] = M.text(item, 160) end end
    state.plan = {digest = digest, ready = value.ready == true, base_revision = integer(value.base_revision), modules = modules,
        missing = missing, migrations = migrations, starts = starts, capabilities = capabilities}
    state.selected_operation, state.recovery = nil, nil
    state.phase, state.notice = "plan", ""
end

function M.confirm(state: State): string?
    if not state.plan then return "prepare a plan first" end
    if not state.plan.ready then return "fill missing values before confirmation" end
    state.phase, state.notice = "confirm", ""
    return nil
end

function M.apply_result(state: State, reply: Reply)
    local receipt = object(reply.value)
    local code = M.text(reply.code or (reply.ok and "OK" or "FAILED"), 80)
    local message = M.text(reply.message or receipt.message or "Hub operation finished", 512)
    local status = M.text(receipt.state or (reply.ok and "unknown" or "failed"), 80)
    local complete = reply.ok and status == "complete"
    state.result = {ok = complete, code = code, message = message, replayed = reply.replayed, state = status}
    state.recovery = nil
    if code == "STALE" then state.plan = nil end
    state.phase = "result"
end

return M
