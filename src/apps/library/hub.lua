-- MIT. The Library's Hub package model, a presentation model. It never calls
-- Hub or the registry: the application sends typed intents to the public Hub
-- facade and folds its replies back here.
local json = require("json")
local canonical = require("canonical")
local hash = require("hash")
local text = require("text")
local bounds = require("bounds")
local form = require("form")
local M = {}

M.MAX_TEXT = 512
M.MAX_PARAMETERS = 128
M.MAX_ITEMS = 100
M.MAX_ROOTS = 16384
M.MAX_PLAN_ITEMS = 4096
M.HUB = "bee.hub.binding:call"

type Object = {[string]: unknown}
type Reply = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Intent = {operation: string, request: Object?, expected_digest: string?}
type Phase = "catalog" | "installed" | "details" | "operations" | "plan" | "confirm" | "result"
type Item = {component: string, title: string, description: string, latest_version: string, application: boolean?}
type Version = {version: string, yanked: boolean}
type Detail = {component: string, title: string, description: string, readme: string, readme_error: string, versions: {Version}, page: integer, total_versions: integer}
type Module = {component: string, version: string, source: string, direct: boolean, used_by: {string}}
type PackUpdate = {component: string, installed_version: string, available_version: string, update_available: boolean}
type BeeUpdate = {installed_version: string, available_version: string, update_available: boolean, needs_new_binary: boolean, reason: string}
type Parameter = {name: string, value: unknown, json: string}
type Root = {id: string, component: string, version: string, parameters: {Parameter}, managed: boolean}
type Requirement = {id: string, json: string, origin: string, targets: {string}, field: form.Field?}
type RootSelection = {id: string, component: string}
type Plan = {conversion: {roots: {RootSelection}}?, digest: string, ready: boolean, base_revision: integer, modules: {Object}, missing: {string}, migrations: {Object}, starts: {string}, capabilities: {string}}
type Result = {ok: boolean, code: string, message: string, replayed: boolean, state: string}
type Operation = {digest: string, component: string, action: string, state: string, message: string, baseline_revision: integer, request: Object?, migration_work: {Object}}
type Recovery = {digest: string, request: Object, operation: Operation}
type State = {
    phase: Phase, keyword: string, query: string, page: integer, catalog: {Item}, all_catalog: {Item}?, total: integer,
    developer_packages: boolean, pack_updates: {PackUpdate}, bee_update: BeeUpdate?, update_status: string,
    installed: {Module}, installed_roots: {Root}, installed_read: "unknown" | "pending" | "ready" | "error", selected: string?, detail: Detail?, selected_version: string?,
    requirements_open: boolean, requirements: {Requirement}, requirements_digest: string?, selected_requirement: integer,
    configuration: {form.Declaration}?, configuration_targets: {[string]: {string}}?,
    action: string, policy: string, parameters: {Parameter}, parameter_touched: {[string]: boolean}, plan: Plan?, result: Result?, notice: string,
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

local function object(value: unknown): Object?
    return bounds.object(value)
end

-- Replies are owned by the transport. Keep an immutable recovery request in
-- the model so later catalog, parameter, or selection changes cannot rewrite
-- what a recovery confirmation will publish.
local function clone(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(value) do result[clone(key)] = clone(item) end
    return result
end

local function integer(value: unknown): integer?
    return bounds.count(value)
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

local function object_list(raw: unknown, label: string, maximum: integer): ({Object}?, string?)
    local rows, rows_error = bounds.dense_list(raw, maximum, label)
    if not rows then return nil, rows_error end
    local result: {Object} = {}
    for index, item in ipairs(rows) do
        local value = object(item)
        if not value then return nil, label .. " item " .. tostring(index) .. " must be an object" end
        result[index] = value
    end
    return result, nil
end

local function string_list(raw: unknown, label: string, maximum: integer): ({string}?, string?)
    local rows, rows_error = bounds.dense_list(raw, maximum, label)
    if not rows then return nil, rows_error end
    local result: {string} = {}
    for index, item in ipairs(rows) do
        local value = bounds.line(item, 160)
        if not value then return nil, label .. " item " .. tostring(index) .. " is invalid" end
        result[index] = value
    end
    return result, nil
end

local function operation_request(raw: unknown, action: string, owner: string): Object?
    local value = object(raw)
    if not value then return nil end
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
    for index, raw_parameter in ipairs(value.parameters) do
        if index > M.MAX_PARAMETERS then return nil end
        local parameter = object(raw_parameter)
        if not parameter then return nil end
        local name = type(parameter.name) == "string" and parameter.name or ""
        if name == "" or #name > 256 or not name:match("^[^:%s]+:[^:%s]+$") or parameter.value == nil then return nil end
        parameters[index] = {name = name, value = clone(parameter.value)}
    end
    result.version, result.parameters = selected_version, parameters
    return result
end

local function parameter_rows(raw: unknown): ({Parameter}?, string?)
    local rows, rows_error = bounds.dense_list(raw, M.MAX_PARAMETERS, "installed root parameters")
    if not rows then return nil, rows_error end
    local parameters: {Parameter} = {}
    local seen: {[string]: boolean} = {}
    for index, raw_parameter in ipairs(rows) do
        local parameter = object(raw_parameter)
        if not parameter then return nil, "installed root has an invalid parameter" end
        local name = parameter.name
        -- Installed roots address requirements the way the native linker does:
        -- a qualified ns:name or a bare name the dependency owns.
        if type(name) ~= "string" or #name == 0 or #name > 256 or seen[name]
            or not (name:match("^[^:%s]+$") or name:match("^[^:%s]+:[^:%s]+$")) then
            return nil, "installed root has an invalid parameter name"
        end
        if parameter.value == nil then return nil, "installed root parameter has no value" end
        local encoded, encoding_error = json.encode(parameter.value)
        if not encoded or encoding_error or #encoded > 8192 then return nil, "installed root parameter value is invalid" end
        parameters[index] = {name = name, value = clone(parameter.value), json = encoded}
        seen[name] = true
    end
    return parameters, nil
end

local function root_rows(raw: unknown): ({Root}?, string?)
    if raw == nil then return nil, "installed inventory did not include roots" end
    local rows, rows_error = bounds.dense_list(raw, M.MAX_ROOTS, "installed inventory roots")
    if not rows then return nil, rows_error end
    local roots: {Root} = {}
    local seen: {[string]: boolean} = {}
    for index, raw_item in ipairs(rows) do
        local item = object(raw_item)
        if not item then return nil, "installed inventory contains an invalid root" end
        local id = item.id
        local name = component(item.component)
        local selected = version(item.version)
        if type(id) ~= "string" or #id == 0 or #id > 256 or id:find("%c") or not name or not selected or type(item.managed) ~= "boolean" then
            return nil, "installed inventory contains an invalid root"
        end
        if seen[id] then return nil, "installed inventory contains duplicate roots" end
        local parameters, parameter_error = parameter_rows(item.parameters)
        if not parameters then return nil, parameter_error end
        seen[id] = true
        roots[index] = {id = id, component = name, version = selected, parameters = parameters, managed = item.managed == true}
    end
    table.sort(roots, function(a: Root, b: Root): boolean return a.id < b.id end)
    return roots, nil
end

local function copy_parameter(parameter: Parameter): Parameter
    return {name = parameter.name, value = clone(parameter.value), json = parameter.json}
end

local function copy_parameters(parameters: {Parameter}): {Parameter}
    local copied: {Parameter} = {}
    for index, parameter in ipairs(parameters) do copied[index] = copy_parameter(parameter) end
    return copied
end

local function managed_root(root: Root): boolean
    return root.managed or root.component == "bee/bee"
end

local function migration_rows(raw: unknown): ({Object}?, string?)
    if raw == nil then return {}, nil end
    local work = object(raw)
    if not work then return nil, "migration work must be an object" end
    local rows: {Object} = {}
    local supplied, supplied_error = bounds.dense_list(work.rows, M.MAX_ITEMS, "migration work rows")
    if not supplied then return nil, supplied_error end
    for index, raw_row in ipairs(supplied) do
        local row = object(raw_row)
        if not row then return nil, "migration work row is malformed" end
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
    return {phase = "catalog", keyword = "bee", query = "", page = 1, catalog = {}, all_catalog = {}, total = 0,
        developer_packages = false, pack_updates = {}, bee_update = nil, update_status = "idle",
        installed = {}, installed_roots = {}, installed_read = "unknown", selected = nil, detail = nil, selected_version = nil, action = "install", policy = "none",
        requirements_open = false, requirements = {}, requirements_digest = nil, selected_requirement = 1,
        parameters = {}, parameter_touched = {}, plan = nil, result = nil, notice = "",
        operation_page = 1, operation_total = 0,
        operation_page_size = 25, operation_detail_offset = 0, operations = {}, selected_operation = nil, recovery = nil}
end

-- Presentation changes have no Hub side effect. Keep them here so clients do
-- not need to reach into the state record just to change panes.
function M.show(state: State, phase: Phase)
    local returning_to_plan = phase == "plan" and state.phase == "confirm" and state.recovery == nil
    if phase ~= "confirm" and not returning_to_plan then state.plan, state.result = nil, nil end
    if phase ~= "confirm" then state.recovery = nil end
    if phase ~= "operations" and phase ~= "confirm" then
        state.selected_operation, state.recovery = nil, nil
    end
    state.phase = phase
end

function M.begin_plan(state: State)
    reset_plan(state)
    M.show(state, "plan")
end

function M.catalog_intent(state: State): Intent
    local request: Object = {keyword = state.keyword, page = state.page}
    if state.query ~= "" then request.query = state.query end
    return {operation = "catalog", request = request}
end

function M.installed_intent(_: State): Intent return {operation = "installed"} end

function M.updates_intent(_: State): Intent return {operation = "updates"} end

function M.begin_updates(state: State)
    state.pack_updates, state.bee_update = {}, nil
    state.update_status = "pending"
end

function M.operation_history_intent(state: State): Intent
    return {operation = "status", request = {page = math.max(1, math.min(10000, state.operation_page))}}
end

function M.apply_history(state: State, reply: Reply)
    if not reply.ok then
        state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "operation history unavailable"))
        return
    end
    local value = object(reply.value)
    local supplied: {unknown}? = nil
    local supplied_error: string? = nil
    if value then supplied, supplied_error = bounds.dense_list(value.operations, M.MAX_ITEMS, "operation history") end
    local page = value and integer(value.page) or nil
    local total = value and integer(value.total) or nil
    local page_size = value and integer(value.page_size) or nil
    if not value or not supplied or not page or page < 1 or page > 10000 or not total
        or not page_size or page_size < 1 or page_size > 100 then
        state.notice = supplied_error or "status reply has malformed history or pagination"
        return
    end
    local operations: {Operation} = {}
    for index, raw in ipairs(supplied) do
        local item = object(raw)
        if not item then state.notice = "status reply contains a malformed operation"; return end
        local measured = digest(item.digest)
        local owner = component(item.component)
        local action = (item.action == "install" and "install") or (item.action == "update" and "update")
            or (item.action == "uninstall" and "uninstall") or nil
        local baseline = item.baseline_revision == nil and 0 or integer(item.baseline_revision)
        if item.baseline_revision ~= nil and baseline == nil then
            state.notice = "status reply contains a malformed baseline revision"; return
        end
        local migration_work, migration_error = migration_rows(item.migration_work)
        if not migration_work then state.notice = migration_error or "status reply contains malformed migration work"; return end
        if measured and owner and action and baseline ~= nil then
            local op: Operation = {digest = measured, component = owner, action = action, state = M.text(item.state, 80),
                message = M.text(item.message, 512), baseline_revision = baseline, request = operation_request(item.request, action, owner),
                migration_work = migration_work}
            operations[#operations + 1] = op
        end
    end
    table.sort(operations, function(a: Operation, b: Operation): boolean
        if a.baseline_revision ~= b.baseline_revision then return a.baseline_revision > b.baseline_revision end
        return a.digest > b.digest
    end)
    state.operations, state.operation_page = operations, page
    state.operation_total, state.operation_page_size = total, page_size
    if state.selected_operation then
        local selected = state.selected_operation.digest
        state.selected_operation = nil
        for _, operation in ipairs(operations) do
            if operation.digest == selected then state.selected_operation = operation; break end
        end
    end
    if state.recovery and (not state.selected_operation or state.recovery.digest ~= state.selected_operation.digest
        or (state.selected_operation.state ~= "prepared" and state.selected_operation.state ~= "published" and state.selected_operation.state ~= "recovery_required")) then
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
    if operation.state ~= "prepared" and operation.state ~= "published" and operation.state ~= "recovery_required" then
        return "only prepared, published or recovery-required operations can be recovered"
    end
    if not operation.request then return "this operation has no stored request for recovery" end
    local preserved = clone(operation.request)
    if type(preserved) ~= "table" then return "this operation has no stored request for recovery" end
    state.recovery = {digest = operation.digest, request = preserved, operation = operation}
    state.phase, state.notice = "confirm", ""
    return nil
end

function M.details_intent(state: State): Intent?
    if not state.selected then return nil end
    return {operation = "details", request = {component = state.selected, page = state.detail and state.detail.page or 1}}
end

function M.inspect_intent(state: State): Intent?
    if not state.selected or not state.selected_version then return nil end
    if state.action == "update" and state.installed_read ~= "ready" then return nil end
    local parameters: {Object} = {}
    for index, parameter in ipairs(state.parameters) do parameters[index] = {name = parameter.name, value = parameter.value} end
    return {operation = "inspect", request = {component = state.selected, version = state.selected_version, parameters = parameters}}
end

function M.plan_intent(state: State): (Intent?, string?)
    if not state.selected then return nil, "select a package first" end
    if state.action ~= "uninstall" and not state.selected_version then return nil, "select an exact package version" end
    if state.action ~= "uninstall" then
        for _, declaration in ipairs(state.configuration or {}) do
            local value = declaration.default
            for _, parameter in ipairs(state.parameters) do if parameter.name == declaration.id then value = parameter.value end end
            local problem = form.validate(declaration, value)
            if problem then return nil, problem end
        end
    end
    if state.action == "update" then
        if state.installed_read ~= "ready" then return nil, state.installed_read == "error"
            and "installed settings could not be read; retry the inventory read before updating"
            or "installed settings are still loading; retry after the inventory read completes" end
    end
    local parameters: {Object} = {}
    if state.action ~= "uninstall" then
        for index, parameter in ipairs(state.parameters) do parameters[index] = {name = parameter.name, value = parameter.value} end
    end
    local request: Object = {action = state.action, component = state.selected, migration_policy = state.policy}
    if state.action ~= "uninstall" then request.version, request.parameters = state.selected_version, parameters end
    return {operation = "plan", request = request}, nil
end

function M.governed_request(state: State, reply: Reply, workspace_id: string, key: string): (Object?, string?)
    local value = reply.ok and object(reply.value) or nil
    if not value or value.route ~= "governed" then return nil, nil end
    local measured = digest(value.artifact_digest)
    if value.component ~= state.selected or value.version ~= state.selected_version or not measured
        or state.action == "uninstall" then return nil, "Application plan does not match the selected version" end
    local parameters: {Object} = {}
    for _, parameter in ipairs(state.parameters) do parameters[#parameters + 1] = {name = parameter.name, value = parameter.value} end
    return {operation = "stage_hub", workspace_id = workspace_id, component = value.component,
        version = value.version, parameters = parameters,
        artifact_digest = measured, idempotency_key = key}, nil
end

function M.confirm_intent(state: State): (Intent?, string?)
    if state.phase ~= "confirm" then return nil, "review confirmation before applying" end
    if state.recovery then
        local request = clone(state.recovery.request)
        if type(request) ~= "table" then return nil, "recovery request is unavailable" end
        return {operation = "apply", request = request, expected_digest = state.recovery.digest}, nil
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
-- The keyword filter opens on the catalog phase, where the footer advertises
-- it; on other phases the same key keeps its selection meaning.
function M.keyword_phase(phase: string): boolean
    return phase == "catalog"
end

local update_catalog_visibility: ((State) -> ())? = nil

function M.set_query(state: State, value: unknown)
    local selected = M.text(value, 160)
    if selected ~= state.query then
        state.query, state.page = selected, 1
        if update_catalog_visibility then update_catalog_visibility(state) end
        reset_plan(state)
    end
end

function M.set_page(state: State, page: integer)
    local selected = math.max(1, math.min(10000, math.floor(page)))
    if selected ~= state.page then state.page = selected; reset_plan(state) end
end

function M.select(state: State, name: string?)
    if name ~= state.selected then
        state.selected, state.detail, state.selected_version, state.parameters = name, nil, nil, {}
        state.parameter_touched = {}
        state.requirements, state.requirements_digest, state.selected_requirement = {}, nil, 1
        state.configuration, state.configuration_targets = nil, nil
        state.action, state.policy = "install", "none"
        reset_plan(state)
    end
    if name then state.phase = "details" else state.phase = "catalog" end
end

function M.select_version(state: State, selected: string?)
    if selected ~= state.selected_version then
        state.selected_version = selected
        state.requirements, state.requirements_digest, state.selected_requirement = {}, nil, 1
        state.configuration, state.configuration_targets = nil, nil
        reset_plan(state)
    end
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
        if action == "update" then M.hydrate_update_parameters(state) end
        reset_plan(state)
    end
end

function M.hydrate_update_parameters(state: State): boolean
    if state.action ~= "update" then return false end
    local saved: {[string]: Parameter} = {}
    if state.selected then
        for _, root in ipairs(state.installed_roots) do
            if root.component == state.selected and managed_root(root) then
                for _, parameter in ipairs(root.parameters) do saved[parameter.name] = parameter end
                break
            end
        end
    end
    local hydrated: {Parameter} = {}
    for name, parameter in pairs(saved) do
        if not state.parameter_touched[name] then hydrated[#hydrated + 1] = copy_parameter(parameter) end
    end
    for _, parameter in ipairs(state.parameters) do
        if state.parameter_touched[parameter.name] then hydrated[#hydrated + 1] = parameter end
    end
    table.sort(hydrated, function(a: Parameter, b: Parameter): boolean return a.name < b.name end)
    state.parameters = hydrated
    return true
end

function M.begin_update_hydration(state: State)
    if state.action == "update" then state.installed_read, state.notice = "pending", "Loading installed settings…" end
end

function M.set_policy(state: State, policy: string)
    local uninstall = state.action == "uninstall"
    local valid = (uninstall and (policy == "block" or policy == "leave" or policy == "down"))
        or (not uninstall and (policy == "none" or policy == "up"))
    if valid and policy ~= state.policy then state.policy = policy; reset_plan(state) end
end

local function refresh_fields(state: State)
    if not state.configuration then return end
    local values: {[string]: unknown} = {}
    for _, parameter in ipairs(state.parameters) do values[parameter.name] = parameter.value end
    local rows: {Requirement} = {}
    local fields, problem = form.fields(state.configuration, values)
    if problem then state.notice = problem; state.requirements_digest = nil end
    for _, field in ipairs(fields) do
        rows[#rows + 1] = {id = field.id, json = field.value ~= nil and (json.encode(field.value) or "") or "",
            origin = field.origin, targets = state.configuration_targets and state.configuration_targets[field.root] or {}, field = field}
    end
    state.requirements = rows
end

local function write_parameter(state: State, id: string, value: unknown, normalized: string): string?
    for _, parameter in ipairs(state.parameters) do
        if parameter.name == id then
            parameter.value, parameter.json = value, normalized
            state.parameter_touched[id] = true
            reset_plan(state)
            refresh_fields(state)
            return nil
        end
    end
    if #state.parameters >= M.MAX_PARAMETERS then return "too many parameters" end
    state.parameters[#state.parameters + 1] = {name = id, value = value, json = normalized}
    table.sort(state.parameters, function(a: Parameter, b: Parameter): boolean return a.name < b.name end)
    state.parameter_touched[id] = true
    reset_plan(state)
    refresh_fields(state)
    return nil
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
    if state.configuration then
        local found = false
        for _, declaration in ipairs(state.configuration) do
            if declaration.id == id then
                if declaration.capability then return id .. ": capability grants are selected by the host" end
                local problem = form.validate(declaration, value)
                if problem then return problem end
                found = true
            end
        end
        if not found then return "parameter names no requirement " .. id end
    end
    return write_parameter(state, id, value, normalized)
end

local function write_field(state: State, field: form.Field, value: unknown): string?
    if field.readonly then return field.root .. ": supplied by the host" end
    local root: unknown = nil
    for _, declaration in ipairs(state.configuration or {}) do if declaration.id == field.root then root = declaration.default end end
    for _, parameter in ipairs(state.parameters) do if parameter.name == field.root then root = parameter.value end end
    local assigned = form.assign(root, field.path, value)
    local encoded = json.encode(assigned)
    if not encoded then return field.id .. ": value cannot be represented" end
    return write_parameter(state, field.root, assigned, encoded)
end

function M.set_field(state: State, name: string, input: string): string?
    for _, row in ipairs(state.requirements) do
        local field = row.field
        if row.id == name and field then
            local value, problem = form.parse(field, input)
            if problem then return problem end
            return write_field(state, field, value)
        end
    end
    return "Choose a configuration field"
end

function M.field_buffer(row: Requirement): string
    return row.field and form.buffer(row.field) or row.json
end

function M.cycle_field(state: State, name: string, step: integer): string?
    for _, row in ipairs(state.requirements) do
        local field = row.field
        if row.id == name and field then
            if field.readonly then return field.root .. ": supplied by the host" end
            if #field.choices > 0 then
                local index = step > 0 and 0 or 1
                for position, value in ipairs(field.choices) do
                    if canonical.encode(value) == canonical.encode(field.value) then index = position end
                end
                local value = field.choices[(index - 1 + step) % #field.choices + 1]
                local problem = form.validate({id = field.id, schema = field.schema, default = nil, has_default = false}, value)
                if problem then return problem end
                return write_field(state, field, value)
            elseif field.kind == "boolean" then return M.set_field(state, name, field.value == true and "false" or "true") end
            return "Enter edits this field"
        end
    end
    return "Choose a configuration field"
end

function M.add_field_item(state: State, name: string): string?
    for _, row in ipairs(state.requirements) do
        local field = row.field
        if row.id == name and field and field.kind == "array" then
            local items = bounds.object(field.schema.items)
            if not items then return "This list has no declared item schema" end
            local value = clone(field.value or {})
            if type(value) ~= "table" then return "This field is not a list" end
            if #value >= 128 then return "This list reaches its item limit" end
            value[#value + 1] = items.default or {}
            return write_field(state, field, value)
        end
    end
    return "Choose a list field"
end

function M.remove_parameter(state: State, name: string)
    for index, parameter in ipairs(state.parameters) do
        if parameter.name == name then table.remove(state.parameters, index); state.parameter_touched[name] = true; reset_plan(state); refresh_fields(state); return end
    end
end

-- Reject incomplete or stale declarations; never manufacture defaults or types.
local function requirement_list(raw: unknown, maximum: integer): {unknown}?
    local rows = bounds.dense_list(raw, maximum, "package declaration")
    return rows
end

function M.apply_inspect(state: State, reply: Reply)
    state.requirements, state.requirements_digest = {}, nil
    state.configuration, state.configuration_targets = nil, nil
    if not reply.ok then state.notice = M.text(reply.message or "Requirements unavailable"); return end
    local value = object(reply.value)
    if not value then state.notice = "Invalid package requirements"; return end
    local measured = digest(value.digest)
    if value.component ~= state.selected or value.version ~= state.selected_version or not measured then
        state.notice = "Requirements did not match the selected package version"; return
    end
    local requirements = object(value.requirements)
    local rows = requirements and requirement_list(requirements.requirements, M.MAX_PARAMETERS) or nil
    if not rows then state.notice = "Invalid package requirements"; return end
    local decoded: {Requirement}, seen: {[string]: boolean} = {}, {}
    local declarations: {form.Declaration}, configuration_targets: {[string]: {string}} = {}, {}
    for _, raw in ipairs(rows) do
        local row = object(raw)
        if not row then state.notice = "Invalid package requirement"; return end
        local id = row.id
        local targets = requirement_list(row.targets, 128)
        if type(id) ~= "string" or #id > 256 or not id:match("^[^:%s]+:[^:%s]+$") or seen[id]
            or type(row.has_default) ~= "boolean" or type(row.has_selected) ~= "boolean" or not targets then
            state.notice = "Invalid package requirement"; return
        end
        local encoded, origin = "", "Required"
        if row.has_selected or row.has_default then
            local selected = row.default
            origin = "Default"
            if row.has_selected then selected = row.selected; origin = "Selected" end
            local result, problem = json.encode(selected)
            if not result or problem or #result > 8192 then state.notice = "Invalid requirement value"; return end
            encoded = result
        end
        local paths: {string} = {}
        for _, raw_target in ipairs(targets) do
            local target = object(raw_target)
            if not target then state.notice = "Invalid requirement target"; return end
            if type(target.entry) ~= "string" or type(target.path) ~= "string" or #target.entry > 256 or #target.path > 512 then
                state.notice = "Invalid requirement target"; return
            end
            paths[#paths + 1] = M.text(target.entry, 256) .. " " .. M.text(target.path, 512)
        end
        decoded[#decoded + 1] = {id = id, json = encoded, origin = origin, targets = paths}
        local schema = row.schema == nil and {} or bounds.object(row.schema)
        if not schema then state.notice = id .. ": Invalid declared schema"; return end
        local capability = row.capability == nil and nil or bounds.text(row.capability, 80)
        declarations[#declarations + 1] = {id = id, schema = schema, default = row.default, has_default = row.has_default,
            capability = capability, description = bounds.text(row.description, 4096)}
        configuration_targets[id] = paths
        seen[id] = true
    end
    state.requirements, state.requirements_digest, state.notice = decoded, measured, ""
    state.configuration, state.configuration_targets = declarations, configuration_targets
    refresh_fields(state)
    state.selected_requirement = math.floor(math.max(1, math.min(#decoded, state.selected_requirement)))
end

function M.show_requirements(state: State, visible: boolean)
    state.requirements_open = visible
end

function M.select_requirement(state: State, index: integer)
    state.selected_requirement = math.floor(math.max(1, math.min(#state.requirements, index)))
end

function M.is_library(item: Item): boolean
    return item.application == false
end

local function component_status_installed(installed: {Module}, comp_name: string): string?
    for _, mod in ipairs(installed) do
        if mod.component == comp_name then
            if mod.source == "builtin" or mod.source == "core" or mod.source == "system" then
                return "built-in"
            end
            return "installed"
        end
    end
    return nil
end

function M.component_status(state: State, comp_name: string): string?
    return component_status_installed(state.installed, comp_name)
end

local function ensure_selected_visible(state: State)
    local items = state.catalog
    if #items == 0 then return end
    if not state.selected then
        state.selected = items[1].component
        return
    end
    for _, item in ipairs(items) do
        if item.component == state.selected then
            return
        end
    end
    state.selected = items[1].component
end

function M.visible_catalog(state: State): {Item}
    local source = state.all_catalog or state.catalog
    if state.developer_packages then
        return source
    end
    local apps: {Item} = {}
    for _, item in ipairs(source) do
        if item.application == true then
            apps[#apps + 1] = item
        end
    end
    return apps
end

update_catalog_visibility = function(state: State)
    state.catalog = M.visible_catalog(state)
    ensure_selected_visible(state)
end

function M.toggle_developer_packages(state: State)
    state.developer_packages = not state.developer_packages
    if update_catalog_visibility then update_catalog_visibility(state) end
    reset_plan(state)
end

function M.set_developer_packages(state: State, enabled: boolean)
    state.developer_packages = enabled == true
    if update_catalog_visibility then update_catalog_visibility(state) end
    reset_plan(state)
end

local function catalog_rank(installed: {Module}, item: Item): integer
    local is_app = not M.is_library(item)
    local status = component_status_installed(installed, item.component)
    if is_app then
        if status == "built-in" then return 1 end
        if status == "installed" then return 2 end
        return 3
    else
        if status == "built-in" or status == "installed" then return 4 end
        return 5
    end
end

function M.apply_catalog(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "catalog unavailable")); return end
    local value = object(reply.value)
    local total = value and integer(value.total) or nil
    local supplied: {unknown}? = nil
    local supplied_error: string? = nil
    if value then supplied, supplied_error = bounds.dense_list(value.items, M.MAX_ITEMS, "Hub catalog items") end
    if not value or not total or not supplied then state.notice = supplied_error or "Invalid catalog reply"; return end
    local rows: {Item} = {}
    for _, raw in ipairs(supplied) do
        local item = object(raw)
        if not item then state.notice = "Invalid catalog item"; return end
        local name = component(item.component)
        local application: boolean? = nil
        if type(item.application) == "boolean" then application = item.application end
        if item.application ~= nil and application == nil then state.notice = "Invalid application metadata"; return end
        if name then rows[#rows + 1] = {component = name, title = M.text(item.title, 160),
            description = M.text(item.description, 512), latest_version = M.text(item.latest_version, 128), application = application} end
    end
    local installed = state.installed
    table.sort(rows, function(a: Item, b: Item): boolean
        local ra, rb = catalog_rank(installed, a), catalog_rank(installed, b)
        if ra ~= rb then return ra < rb end
        return a.component < b.component
    end)
    state.all_catalog = rows
    state.total, state.notice = total, ""
    if update_catalog_visibility then update_catalog_visibility(state) end
end

function M.apply_installed(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then
        state.installed_read = "error"
        state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "installed modules unavailable")); return
    end
    local value = object(reply.value)
    if not value then
        state.installed_read = "error"
        state.notice = "Invalid installed inventory: reply must be an object"; return
    end
    local rows: {Module} = {}
    local roots, root_error = root_rows(value.roots)
    if not roots then
        state.installed_read = "error"
        state.notice = "Invalid installed inventory: " .. (root_error or "invalid roots"); return
    end
    local supplied, supplied_error = bounds.dense_list(value.modules, M.MAX_ITEMS, "installed modules")
    if not supplied then
        state.installed_read = "error"
        state.notice = "Invalid installed inventory: " .. (supplied_error or "invalid modules"); return
    end
    for _, raw in ipairs(supplied) do
        local item = object(raw)
        if not item then
            state.installed_read = "error"
            state.notice = "Invalid installed inventory: malformed module"; return
        end
        local name = component(item.component)
        if name then
            local used: {string} = {}
            if item.used_by ~= nil then
                local owners = bounds.dense_list(item.used_by, M.MAX_ITEMS, "module owners")
                if not owners then
                    state.installed_read = "error"
                    state.notice = "Invalid installed inventory: malformed module owners"; return
                end
                for _, owner in ipairs(owners) do
                    if type(owner) ~= "string" then
                        state.installed_read = "error"
                        state.notice = "Invalid installed inventory: malformed module owner"; return
                    end
                    used[#used + 1] = M.text(owner, 160)
                end
            end
            rows[#rows + 1] = {component = name, version = M.text(item.version, 128), source = M.text(item.source, 80), direct = item.direct == true, used_by = used}
        end
    end
    state.installed, state.installed_roots = rows, roots
    state.installed_read = "ready"
    M.hydrate_update_parameters(state)
    if state.phase == "catalog" or state.phase == "installed" then state.phase = "installed" end
    state.notice = ""
end

function M.apply_updates(state: State, reply: Reply)
    state.pack_updates, state.bee_update = {}, nil
    if not reply.ok or type(reply.value) ~= "table" then
        state.update_status = "error"
        state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "Bee update status unavailable"))
        return
    end
    local value = object(reply.value)
    if not value then state.update_status = "error"; state.notice = "Invalid Bee update status"; return end
    local supplied, supplied_error = bounds.dense_list(value.modules, M.MAX_ITEMS, "Bee pack status")
    local root = object(value.bee_update)
    if not supplied or not root or type(root.update_available) ~= "boolean" or type(root.needs_new_binary) ~= "boolean" then
        state.update_status = "error"; state.notice = supplied_error or "Invalid Bee root update status"; return
    end
    local packs: {PackUpdate} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(supplied) do
        local item = object(raw)
        local name = item and component(item.component)
        if not item or not name or seen[name]
            or type(item.update_available) ~= "boolean" then
            state.update_status = "error"; state.notice = "Invalid Bee pack update row"; return
        end
        packs[#packs + 1] = {component = name, installed_version = M.text(item.installed_version, 128),
            available_version = M.text(item.available_version, 128), update_available = item.update_available}
        seen[name] = true
    end
    state.pack_updates = packs
    state.bee_update = {installed_version = M.text(root.installed_version, 128),
        available_version = M.text(root.available_version, 128), update_available = root.update_available,
        needs_new_binary = root.needs_new_binary,
        reason = M.text(root.reason, 512)}
    state.update_status = "ready"
    if type(value.catalog_error) == "string" and value.catalog_error ~= "" then
        state.notice = M.text(value.catalog_error, 512)
    end
end

function M.apply_details(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "package details unavailable")); return end
    local value = object(reply.value)
    if not value then state.notice = "Invalid package details"; return end
    local name = component(value.component)
    if not name or name ~= state.selected then state.notice = "details did not match the selected package"; return end
    local page, total_versions = integer(value.page), integer(value.total_versions)
    local supplied = bounds.dense_list(value.versions, M.MAX_ITEMS, "Hub versions")
    if not page or page < 1 or not total_versions or not supplied then state.notice = "Invalid package details pagination"; return end
    local versions: {Version} = {}
    for _, raw in ipairs(supplied) do
        local item = object(raw)
        if not item or type(item.yanked) ~= "boolean" then state.notice = "Invalid package version"; return end
        local selected = version(item.version)
        if selected then versions[#versions + 1] = {version = selected, yanked = item.yanked} end
    end
    state.detail = {component = name, title = M.text(value.title, 160), description = M.text(value.description, 512),
        readme = readme(value.readme), readme_error = M.text(value.readme_error, 512), versions = versions, page = page,
        total_versions = total_versions}
    if not state.selected_version then for _, item in ipairs(versions) do if not item.yanked then state.selected_version = item.version; break end end end
    state.phase, state.notice = "details", ""
end

local function matches_request(state: State, raw: unknown): boolean
    local intent = M.plan_intent(state)
    if not intent or not intent.request then return false end
    local expected, actual = intent.request, object(raw)
    if not actual then return false end
    if expected.action ~= actual.action or expected.component ~= actual.component
        or expected.migration_policy ~= actual.migration_policy then return false end
    -- The public uninstall request omits version/parameters. The measured
    -- backend plan returns their normalized empty values.
    if expected.action == "uninstall" then
        return actual.version == "" and type(actual.parameters) == "table" and next(actual.parameters) == nil
    end
    if expected.version ~= actual.version then return false end
    local expected_parameters = bounds.dense_list(expected.parameters, M.MAX_PARAMETERS, "plan parameters")
    local actual_parameters = bounds.dense_list(actual.parameters, M.MAX_PARAMETERS, "returned plan parameters")
    if not expected_parameters or not actual_parameters or #expected_parameters ~= #actual_parameters then return false end
    for index, expected_parameter in ipairs(expected_parameters) do
        local left, right = object(expected_parameter), object(actual_parameters[index])
        if not left or not right then return false end
        local left_value, right_value = canonical.encode(left.value), canonical.encode(right.value)
        if left.name ~= right.name or not left_value or not right_value or left_value ~= right_value then return false end
    end
    return true
end

function M.apply_plan(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.plan = nil; state.phase = "plan"; state.notice = M.text((reply.code or "INVALID") .. ": " .. (reply.message or "cannot review these changes")); return end
    local value = object(reply.value)
    if not value then state.notice = "The Hub answered something unreadable; try Refresh"; return end
    local measured_digest = digest(value.digest)
    if not measured_digest then state.notice = "The Hub answered something unreadable; try Refresh"; return end
    local base_revision = integer(value.base_revision)
    if base_revision == nil then state.notice = "The Hub answered something unreadable; try Refresh"; return end
    if type(value.ready) ~= "boolean" then state.notice = "The Hub answered something unreadable; try Refresh"; return end
    if not matches_request(state, value.request) then state.notice = "Those changes were for an earlier choice and were ignored"; return end
    local modules, modules_error = object_list(value.modules, "plan modules", M.MAX_PLAN_ITEMS)
    local migrations, migrations_error = object_list(value.migrations, "plan migrations", M.MAX_PLAN_ITEMS)
    local missing, missing_error = string_list(value.missing, "plan missing requirements", M.MAX_PLAN_ITEMS)
    local starts, starts_error = string_list(value.starts, "plan starts", M.MAX_PLAN_ITEMS)
    local capabilities, capabilities_error = string_list(value.capabilities, "plan capabilities", M.MAX_PLAN_ITEMS)
    if not modules or not migrations or not missing or not starts or not capabilities then
        state.notice = modules_error or migrations_error or missing_error or starts_error or capabilities_error
            or "The Hub answered something unreadable; try Refresh"
        return
    end
    local conversion: {roots: {RootSelection}}? = nil
    if value.conversion ~= nil then
        local supplied = object(value.conversion)
        local roots = supplied and object_list(supplied.roots, "component root conversion", 128) or nil
        if not supplied or supplied.version ~= 1 or not roots then state.notice = "Hub returned malformed root conversion"; return end
        local selected: {RootSelection} = {}
        for _, root in ipairs(roots) do
            local name = component(root.component)
            local id = bounds.id(root.id)
            if not name or not id then state.notice = "Hub returned malformed root conversion"; return end
            selected[#selected + 1] = {id = id, component = name}
        end
        conversion = {roots = selected}
    end
    state.plan = {digest = measured_digest, ready = value.ready, base_revision = base_revision, modules = modules,
        missing = missing, migrations = migrations, starts = starts, capabilities = capabilities, conversion = conversion}
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
    local message = M.text(reply.message or (receipt and receipt.message) or "Hub operation finished", 512)
    local status = M.text((receipt and receipt.state) or (reply.ok and "unknown" or "failed"), 80)
    local complete = reply.ok and status == "complete"
    state.result = {ok = complete, code = code, message = message, replayed = reply.replayed, state = status}
    state.recovery = nil
    if code == "STALE" then state.plan = nil end
    state.phase = "result"
end

return M
