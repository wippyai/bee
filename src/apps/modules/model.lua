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
type Phase = "catalog" | "installed" | "details" | "plan" | "confirm" | "result"
type Item = {component: string, title: string, description: string, latest_version: string}
type Version = {version: string, yanked: boolean}
type Detail = {component: string, title: string, description: string, readme: string, versions: {Version}, page: integer, total_versions: integer}
type Module = {component: string, version: string, source: string, direct: boolean, used_by: {string}}
type Parameter = {name: string, value: unknown, json: string}
type Plan = {digest: string, ready: boolean, base_revision: integer, modules: {Object}, missing: {string}, migrations: {Object}, starts: {string}, capabilities: {string}}
type Result = {ok: boolean, code: string, message: string, replayed: boolean, state: string}
type State = {
    phase: Phase, keyword: string, query: string, page: integer, catalog: {Item}, total: integer,
    installed: {Module}, selected: string?, detail: Detail?, selected_version: string?,
    action: string, policy: string, parameters: {Parameter}, plan: Plan?, result: Result?, notice: string,
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

local function reset_plan(state: State)
    state.plan, state.result = nil, nil
    if state.phase == "plan" or state.phase == "confirm" or state.phase == "result" then state.phase = state.detail and "details" or "catalog" end
end

function M.new(): State
    return {phase = "catalog", keyword = "bee", query = "", page = 1, catalog = {}, total = 0,
        installed = {}, selected = nil, detail = nil, selected_version = nil, action = "install", policy = "none",
        parameters = {}, plan = nil, result = nil, notice = ""}
end

-- Presentation changes have no Hub side effect. Keep them here so clients do
-- not need to reach into the state record just to change panes.
function M.show(state: State, phase: Phase)
    state.phase = phase
end

function M.catalog_intent(state: State): Intent
    local request: Object = {keyword = state.keyword, page = state.page}
    if state.query ~= "" then request.query = state.query end
    return {operation = "catalog", request = request}
end

function M.installed_intent(_: State): Intent return {operation = "installed"} end

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
    local plan = state.plan
    if not plan then return nil, "prepare a plan first" end
    if not plan.ready then return nil, "fill every required package value before confirmation" end
    local intent, problem = M.plan_intent(state)
    if not intent then return nil, problem end
    return {operation = "apply", request = intent.request, expected_digest = plan.digest}, nil
end

function M.status_intent(state: State): Intent?
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
    if expected.action ~= actual.action or expected.component ~= actual.component or expected.version ~= actual.version
        or expected.migration_policy ~= actual.migration_policy then return false end
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
    if code == "STALE" then state.plan = nil end
    state.phase = "result"
end

return M
