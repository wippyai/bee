-- MIT. Modules is a presentation model. It never calls Hub, Governance or the
-- registry: the application sends typed intents to public facades and folds
-- their transaction replies back here.
local json = require("json")
local canonical = require("canonical")
local hash = require("hash")
local text = require("text")
local M = {}

M.MAX_TEXT = 512
M.MAX_PARAMETERS = 128
M.MAX_ITEMS = 100
M.MAX_ROOTS = 16384
M.HUB = "bee.hub:call"
M.PUBLICATION = "bee.governance:publication_call"

type Object = {[string]: unknown}
type Reply = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Intent = {operation: string, request: Object?, expected_digest: string?}
type Phase = "catalog" | "installed" | "authoring" | "details" | "operations" | "plan" | "confirm" | "result"
type Item = {component: string, title: string, description: string, latest_version: string}
type Version = {version: string, yanked: boolean}
type Detail = {component: string, title: string, description: string, readme: string, versions: {Version}, page: integer, total_versions: integer}
type Module = {component: string, version: string, source: string, direct: boolean, used_by: {string}}
type Parameter = {name: string, value: unknown, json: string}
type Root = {id: string, component: string, version: string, parameters: {Parameter}}
type Requirement = {id: string, json: string, origin: string, targets: {string}}
type Plan = {digest: string, ready: boolean, base_revision: integer, modules: {Object}, missing: {string}, migrations: {Object}, starts: {string}, capabilities: {string}}
type Result = {ok: boolean, code: string, message: string, replayed: boolean, state: string}
type Operation = {digest: string, component: string, action: string, state: string, message: string, baseline_revision: integer, request: Object?, migration_work: {Object}}
type Recovery = {digest: string, request: Object, operation: Operation}
type Publication = {component: string, version: string, snapshot_digest: string, descriptor_digest: string}
type State = {
    phase: Phase, keyword: string, query: string, page: integer, catalog: {Item}, total: integer,
    installed: {Module}, installed_roots: {Root}, installed_read: "unknown" | "pending" | "ready" | "error", selected: string?, detail: Detail?, selected_version: string?,
    requirements_open: boolean, requirements: {Requirement}, requirements_digest: string?, selected_requirement: integer,
    action: string, policy: string, parameters: {Parameter}, parameter_touched: {[string]: boolean}, plan: Plan?, result: Result?, notice: string,
    publication_component: string, publication_version: string, publication_snapshot_digest: string, publication_prepared: Publication?,
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

local function parameter_rows(raw: unknown): ({Parameter}?, string?)
    if type(raw) ~= "table" then return nil, "installed root parameters must be a list" end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil, "installed root parameters must be a dense list" end
        count = math.max(count, key)
    end
    if count > M.MAX_PARAMETERS then return nil, "installed root has too many parameters" end
    local parameters: {Parameter} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local parameter = object((raw :: {[number]: unknown})[index])
        local name = parameter.name
        if type(name) ~= "string" or #name == 0 or #name > 256 or not name:match("^[^:%s]+:[^:%s]+$") or seen[name] then
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
    if type(raw) ~= "table" then return nil, "installed inventory roots must be a list" end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil, "installed inventory roots must be a dense list" end
        count = math.max(count, key)
    end
    if count > M.MAX_ROOTS then return nil, "installed inventory has too many roots" end
    local roots: {Root} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item = object((raw :: {[number]: unknown})[index])
        local id = item.id
        local name = component(item.component)
        local selected = version(item.version)
        if type(id) ~= "string" or #id == 0 or #id > 256 or id:find("%c") or not name or not selected then
            return nil, "installed inventory contains an invalid root"
        end
        if seen[id] then return nil, "installed inventory contains duplicate roots" end
        local parameters, parameter_error = parameter_rows(item.parameters)
        if not parameters then return nil, parameter_error end
        seen[id] = true
        roots[index] = {id = id, component = name, version = selected, parameters = parameters}
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
    local measured = hash.sha256(root.component)
    return measured ~= nil and root.id == "bee.hub.deps:" .. measured
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
        installed = {}, installed_roots = {}, installed_read = "unknown", selected = nil, detail = nil, selected_version = nil, action = "install", policy = "none",
        requirements_open = false, requirements = {}, requirements_digest = nil, selected_requirement = 1,
        parameters = {}, parameter_touched = {}, plan = nil, result = nil, notice = "",
        publication_component = "", publication_version = "", publication_snapshot_digest = "", publication_prepared = nil,
        operation_page = 1, operation_total = 0,
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

-- Publication identities are entered explicitly. Freeze remains with the
-- caller-owned overlay; host profiles retain source-workspace and
-- overlay authority, and Governance returns only a prepared descriptor.
function M.set_publication_field(state: State, field: string, raw: unknown): string?
    if type(raw) ~= "string" then return "publication value must be text" end
    local value = raw:match("^%s*(.-)%s*$") or ""
    if field == "component" then
        if value ~= "" and not component(value) then return "component must use namespace/name form" end
        state.publication_component = value
    elseif field == "version" then
        if value ~= "" and not version(value) then return "version is invalid" end
        state.publication_version = value
    elseif field == "snapshot_digest" then
        if value ~= "" and not digest(value) then return "snapshot digest must be a lowercase SHA-256 value" end
        state.publication_snapshot_digest = value
    else
        return "unknown publication field"
    end
    state.publication_prepared = nil
    state.notice = ""
    return nil
end

local function publication_identity(state: State, workspace_id: unknown): (string?, string?)
    local workspace = type(workspace_id) == "string" and workspace_id or nil
    if not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then
        return nil, "workspace identity is unavailable"
    end
    if state.phase ~= "authoring" then
        return nil, "open the Authored pane first"
    end
    if not component(state.publication_component) then return nil, "enter a component in namespace/name form" end
    if not version(state.publication_version) then return nil, "enter an explicit version" end
    return workspace :: string, nil
end

function M.publication_prepare_intent(state: State, workspace_id: unknown): (Intent?, string?)
    local workspace, problem = publication_identity(state, workspace_id)
    if not workspace then return nil, problem end
    if not digest(state.publication_snapshot_digest) then
        return nil, "freeze the owned overlay and enter its snapshot digest"
    end
    return {operation = "prepare", request = {operation = "prepare", workspace_id = workspace,
        component = state.publication_component, version = state.publication_version,
        snapshot_digest = state.publication_snapshot_digest}}, nil
end

function M.apply_publication_prepare(state: State, reply: Reply)
    if not reply.ok then
        state.publication_prepared = nil
        state.notice = M.text((reply.code or "FAILED") .. ": " .. (reply.message or "application preparation failed"))
        return
    end
    local value = object(reply.value)
    local descriptor = object(value.descriptor)
    local name, selected_version = component(value.component), version(value.version)
    local descriptor_digest = digest(descriptor.digest)
    if name ~= state.publication_component or selected_version ~= state.publication_version or not descriptor_digest then
        state.publication_prepared = nil
        state.notice = "UNCERTAIN: preparation receipt did not match the selected authored version"
        return
    end
    state.publication_prepared = {component = name, version = selected_version,
        snapshot_digest = state.publication_snapshot_digest, descriptor_digest = descriptor_digest}
    state.notice = (reply.replayed and "Already prepared " or "Prepared locally ") .. name .. " " .. selected_version
        .. "; open Overlays to stage it for local review"
end

function M.publication_ready(state: State): boolean
    local prepared = state.publication_prepared
    return prepared ~= nil and prepared.component == state.publication_component
        and prepared.version == state.publication_version and prepared.snapshot_digest == state.publication_snapshot_digest
end

function M.publication_publish_intent(state: State, workspace_id: unknown): (Intent?, string?)
    local workspace, problem = publication_identity(state, workspace_id)
    if not workspace then return nil, problem end
    if not M.publication_ready(state) then return nil, "prepare this authored version first" end
    return {operation = "publish", request = {operation = "publish", workspace_id = workspace,
        component = state.publication_component, version = state.publication_version}}, nil
end

function M.apply_publication_publish(state: State, reply: Reply)
    if not reply.ok then
        state.notice = M.text((reply.code or "FAILED") .. ": " .. (reply.message or "application publication failed"))
        return
    end
    local value = object(reply.value)
    local name, selected_version = component(value.component), version(value.version)
    if name ~= state.publication_component or selected_version ~= state.publication_version or not M.publication_ready(state) then
        state.notice = "UNCERTAIN: publication receipt did not match the prepared authored version"
        return
    end
    state.notice = (reply.replayed and "Already published " or "Published ") .. name .. " " .. selected_version
        .. "; destinations still make their own review and approval decisions"
end

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
    if state.action == "update" and state.installed_read ~= "ready" then return nil end
    local parameters: {Object} = {}
    for index, parameter in ipairs(state.parameters) do parameters[index] = {name = parameter.name, value = parameter.value} end
    return {operation = "inspect", request = {component = state.selected, version = state.selected_version, parameters = parameters}}
end

function M.plan_intent(state: State): (Intent?, string?)
    if not state.selected then return nil, "select a package first" end
    if state.action ~= "uninstall" and not state.selected_version then return nil, "select an exact package version" end
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
        state.parameter_touched = {}
        state.requirements, state.requirements_digest, state.selected_requirement = {}, nil, 1
        state.action, state.policy = "install", "none"
        reset_plan(state)
    end
    if name then state.phase = "details" else state.phase = "catalog" end
end

function M.select_version(state: State, selected: string?)
    if selected ~= state.selected_version then
        state.selected_version = selected
        state.requirements, state.requirements_digest, state.selected_requirement = {}, nil, 1
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
            state.parameter_touched[id] = true
            reset_plan(state)
            return nil
        end
    end
    if #state.parameters >= M.MAX_PARAMETERS then return "too many parameters" end
    state.parameters[#state.parameters + 1] = {name = id, value = value, json = normalized}
    table.sort(state.parameters, function(a: Parameter, b: Parameter): boolean return a.name < b.name end)
    state.parameter_touched[id] = true
    reset_plan(state)
    return nil
end

function M.remove_parameter(state: State, name: string)
    for index, parameter in ipairs(state.parameters) do
        if parameter.name == name then table.remove(state.parameters, index); state.parameter_touched[name] = true; reset_plan(state); return end
    end
end

-- Reject incomplete or stale declarations; never manufacture defaults or types.
local function requirement_list(raw: unknown, maximum: integer): {unknown}?
    if type(raw) ~= "table" then return nil end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > maximum then return nil end
        count = count + 1
    end
    if count ~= #raw then return nil end
    return raw :: {unknown}
end

function M.apply_inspect(state: State, reply: Reply)
    state.requirements, state.requirements_digest = {}, nil
    if not reply.ok then state.notice = M.text(reply.message or "Requirements unavailable"); return end
    local value = object(reply.value)
    local measured = digest(value.digest)
    if value.component ~= state.selected or value.version ~= state.selected_version or not measured then
        state.notice = "Requirements did not match the selected package version"; return
    end
    local rows = requirement_list(object(value.requirements).requirements, M.MAX_PARAMETERS)
    if not rows then state.notice = "Invalid package requirements"; return end
    local decoded: {Requirement}, seen: {[string]: boolean} = {}, {}
    for _, raw in ipairs(rows) do
        local row = object(raw)
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
            if type(target.entry) ~= "string" or type(target.path) ~= "string" or #target.entry > 256 or #target.path > 512 then
                state.notice = "Invalid requirement target"; return
            end
            paths[#paths + 1] = M.text(target.entry, 256) .. " " .. M.text(target.path, 512)
        end
        decoded[#decoded + 1] = {id = id, json = encoded, origin = origin, targets = paths}
        seen[id] = true
    end
    state.requirements, state.requirements_digest, state.notice = decoded, measured, ""
    state.selected_requirement = math.floor(math.max(1, math.min(#decoded, state.selected_requirement)))
end

function M.show_requirements(state: State, visible: boolean)
    state.requirements_open = visible
end

function M.select_requirement(state: State, index: integer)
    state.selected_requirement = math.floor(math.max(1, math.min(#state.requirements, index)))
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
    if not reply.ok or type(reply.value) ~= "table" then
        state.installed_read = "error"
        state.notice = M.text((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "installed modules unavailable")); return
    end
    local value, rows = object(reply.value), {}
    local roots, root_error = root_rows(value.roots)
    if not roots then
        state.installed_read = "error"
        state.notice = "Invalid installed inventory: " .. (root_error or "invalid roots"); return
    end
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
    state.installed, state.installed_roots = rows, roots
    state.installed_read = "ready"
    M.hydrate_update_parameters(state)
    if state.phase == "catalog" or state.phase == "installed" then state.phase = "installed" end
    state.notice = ""
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
