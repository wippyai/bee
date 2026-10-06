-- MIT. The Library's list model: every application and driver a person can
-- install, from three sources. Versions the agents of this bee made, versions
-- other bees of the hive shared, and Hub packages are folded into one list per
-- tab. This model reads only the models it composes; it calls nothing.
local governed = require("governed")
local hub = require("hub")

local M = {}

type Tab = "installed" | "shared" | "history"
-- The only words a row's status uses.
type Status = "Shared" | "Waiting for your approval" | "Installing" | "Installed" | "Update available" | "Removed"
type Origin = "governed" | "hub"
-- One list row. key is stable across refreshes; update names the newer version
-- an Update available row offers; component names the Hub package.
type Row = {key: string, origin: Origin, name: string, version: string, status: Status, update: string?,
    source: string, note: string, component: string?, available_key: string?, intent_id: string?,
    operation: string?, app: string?}
type Selection = {installed: string?, shared: string?, history: string?}
type Screen = "list" | "version"
type State = {workspace_id: string, tab: Tab, screen: Screen, selected: Selection, governed: governed.State, hub: hub.State,
    notice: string}

M.STATUS_SHARED = "Shared"
M.STATUS_WAITING = "Waiting for your approval"
M.STATUS_INSTALLING = "Installing"
M.STATUS_INSTALLED = "Installed"
M.STATUS_UPDATE = "Update available"
M.STATUS_REMOVED = "Removed"
M.TABS = {"installed", "shared", "history"}

function M.new(workspace_id: string): State
    return {workspace_id = workspace_id, tab = "installed", screen = "list", selected = {installed = nil, shared = nil, history = nil},
        governed = governed.new(workspace_id), hub = hub.new(), notice = ""}
end

-- The application a name stands for: its words capitalized, underscores spoken
-- as spaces.
function M.title(name: string): string
    local spoken = name:gsub("_", " ")
    return spoken:sub(1, 1):upper() .. spoken:sub(2)
end

local function pieces(value: string): {string}
    local parts: {string} = {}
    for part in value:gmatch("[^.%-+]+") do parts[#parts + 1] = part end
    return parts
end

-- compare orders two dotted versions: numeric parts by value, others by text.
function M.compare(left: string, right: string): integer
    local a, b = pieces(left), pieces(right)
    for index = 1, math.max(#a, #b) do
        local x, y = a[index] or "0", b[index] or "0"
        local nx, ny = tonumber(x), tonumber(y)
        if nx ~= nil and ny ~= nil then
            if nx ~= ny then return nx < ny and -1 or 1 end
        elseif x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

-- Where a version came from: this bee's own work, or another bee of the hive.
function M.source(state: State, node: string): string
    if node == state.governed.owner_node then return "made on this bee" end
    return "from bee " .. node:sub(1, 16)
end

type App = {name: string, owner: string, installed: governed.Intent?, flight: governed.Intent?}

-- The applications this workspace holds, newest activity first: an application
-- is installed when its slot observed an applied activation, and on its way
-- while its newest activation has not settled.
local function apps(state: State): {App}
    local order: {string} = {}
    local found: {[string]: App} = {}
    for _, item in ipairs(state.governed.activations) do
        local entry = found[item.overlay_owner]
        if not entry then
            entry = {name = item.source_workspace, owner = item.overlay_owner, installed = nil, flight = nil}
            found[item.overlay_owner] = entry
            order[#order + 1] = item.overlay_owner
            if item.phase ~= "settled" or item.outcome == "uncertain" then entry.flight = item end
        end
        if entry.installed == nil and item.observed_outcome == "applied" and item.intent_id == item.observed_intent_id then
            entry.installed = item
        end
    end
    local result: {App} = {}
    for _, owner in ipairs(order) do
        local entry = found[owner]
        if entry.installed or entry.flight then result[#result + 1] = entry end
    end
    return result
end

local function waiting(item: governed.Intent): boolean
    return item.phase == "prepared" or item.phase == "approval_bound"
end

-- The newest available version of one application name, from any source.
local function newest(state: State, name: string): governed.Available?
    local best: governed.Available? = nil
    for _, item in ipairs(state.governed.available) do
        if item.source_workspace == name and (best == nil or M.compare(item.version, best.version) > 0) then best = item end
    end
    return best
end

local function installed_rows(state: State): {Row}
    local rows: {Row} = {}
    for _, app in ipairs(apps(state)) do
        local flight, current = app.flight, app.installed
        local shown = flight or current
        if shown then
            local row: Row = {key = "g:app:" .. app.name, origin = "governed", name = M.title(app.name),
                version = shown.version, status = M.STATUS_INSTALLED, update = nil,
                source = M.source(state, (current or shown).source_node), note = "", component = nil,
                available_key = nil, intent_id = shown.intent_id, operation = nil, app = app.name}
            if flight then
                row.status = waiting(flight) and M.STATUS_WAITING or M.STATUS_INSTALLING
            elseif current then
                local latest = newest(state, app.name)
                if latest and M.compare(latest.version, current.version) > 0 then
                    row.status, row.update, row.available_key = M.STATUS_UPDATE, latest.version, governed.available_key(latest)
                end
            end
            rows[#rows + 1] = row
        end
    end
    local updates: {[string]: hub.PackUpdate} = {}
    for _, candidate in ipairs(state.hub.pack_updates) do updates[candidate.component] = candidate end
    local modules: {hub.Module} = {}
    for _, module in ipairs(state.hub.installed) do modules[#modules + 1] = module end
    table.sort(modules, function(a: hub.Module, b: hub.Module): boolean
        if a.direct ~= b.direct then return a.direct end
        return a.component < b.component
    end)
    for _, module in ipairs(modules) do
        local built_in = module.source == "builtin" or module.source == "core" or module.source == "system"
        local row: Row = {key = "h:" .. module.component, origin = "hub", name = module.component, version = module.version,
            status = M.STATUS_INSTALLED, update = nil, source = built_in and "built in" or "from Hub",
            note = module.direct and "" or ("needed by " .. table.concat(module.used_by, ", ")),
            component = module.component, available_key = nil, intent_id = nil, operation = nil, app = nil}
        local candidate = updates[module.component]
        if candidate and candidate.update_available and candidate.available_version ~= "" then
            local blocked = module.component == "bee/bee" and state.hub.bee_update ~= nil and state.hub.bee_update.needs_new_binary
            if not blocked then row.status, row.update = M.STATUS_UPDATE, candidate.available_version end
        end
        rows[#rows + 1] = row
    end
    return rows
end

local function shared_rows(state: State): {Row}
    local rows: {Row} = {}
    local held: {[string]: boolean} = {}
    for _, app in ipairs(apps(state)) do held[app.name] = true end
    local best: {[string]: governed.Available} = {}
    local order: {string} = {}
    for _, item in ipairs(state.governed.available) do
        if not held[item.source_workspace] then
            local group = item.owner_id .. "\0" .. item.source_workspace
            local current = best[group]
            if current == nil then order[#order + 1] = group end
            if current == nil or M.compare(item.version, current.version) > 0 then best[group] = item end
        end
    end
    for _, group in ipairs(order) do
        local item = best[group]
        rows[#rows + 1] = {key = "g:ver:" .. governed.available_key(item), origin = "governed",
            name = M.title(item.source_workspace), version = item.version, status = M.STATUS_SHARED, update = nil,
            source = M.source(state, item.owner_id), note = "", component = nil,
            available_key = governed.available_key(item), intent_id = nil, operation = nil, app = item.source_workspace}
    end
    for _, item in ipairs(hub.visible_catalog(state.hub)) do
        if hub.component_status(state.hub, item.component) == nil then
            rows[#rows + 1] = {key = "h:" .. item.component, origin = "hub",
                name = item.title ~= "" and item.title or item.component, version = item.latest_version,
                status = M.STATUS_SHARED, update = nil, source = "from Hub", note = item.component,
                component = item.component, available_key = nil, intent_id = nil, operation = nil, app = nil}
        end
    end
    return rows
end

local function history_rows(state: State): {Row}
    local rows: {Row} = {}
    for _, item in ipairs(state.governed.activations) do
        if item.phase == "settled" and item.outcome ~= "uncertain" then
            local status: Status = M.STATUS_SHARED
            local note = "could not be installed"
            if item.outcome == "applied" then
                note = ""
                status = (item.intent_id == item.observed_intent_id and item.observed_outcome == "applied")
                    and M.STATUS_INSTALLED or M.STATUS_REMOVED
            end
            rows[#rows + 1] = {key = "g:act:" .. item.intent_id, origin = "governed", name = M.title(item.source_workspace),
                version = item.version, status = status, update = nil, source = M.source(state, item.source_node),
                note = note, component = nil, available_key = nil, intent_id = item.intent_id, operation = nil,
                app = item.source_workspace}
        end
    end
    for _, operation in ipairs(state.hub.operations) do
        local status: Status = M.STATUS_SHARED
        local note = "did not finish"
        if operation.state == "complete" then
            note = ""
            status = operation.action == "uninstall" and M.STATUS_REMOVED or M.STATUS_INSTALLED
        elseif operation.state == "prepared" or operation.state == "published" then
            status, note = M.STATUS_INSTALLING, ""
        elseif operation.state == "recovery_required" then
            note = "needs to be finished"
        end
        local requested = operation.request and operation.request.version
        rows[#rows + 1] = {key = "h:op:" .. operation.digest, origin = "hub", name = operation.component,
            version = type(requested) == "string" and requested or "", status = status, update = nil, source = "from Hub",
            note = note, component = operation.component, available_key = nil, intent_id = nil,
            operation = operation.digest, app = nil}
    end
    return rows
end

function M.rows(state: State, tab: Tab?): {Row}
    local shown = tab or state.tab
    if shown == "installed" then return installed_rows(state) end
    if shown == "shared" then return shared_rows(state) end
    return history_rows(state)
end

-- The header's summary: how many applications and packages this bee holds and
-- how many others it could install.
function M.summary(state: State): string
    return tostring(#installed_rows(state)) .. " installed · " .. tostring(#shared_rows(state)) .. " shared"
end

function M.selected_row(state: State): Row?
    local rows = M.rows(state)
    local key = state.selected[state.tab]
    for _, row in ipairs(rows) do if row.key == key then return row end end
    return rows[1]
end

function M.select(state: State, key: string)
    state.selected[state.tab] = key
    state.notice = ""
end

function M.move(state: State, delta: integer)
    local rows = M.rows(state)
    if #rows == 0 then return end
    local current = 1
    local chosen = M.selected_row(state)
    for index, row in ipairs(rows) do if chosen and row.key == chosen.key then current = index; break end end
    local next_index = math.floor(math.max(1, math.min(#rows, current + delta)))
    M.select(state, rows[next_index].key)
end

function M.show_tab(state: State, tab: Tab)
    state.tab, state.screen = tab, "list"
    state.notice = ""
end

-- The version screen reads one governed row in person words.
function M.show_version(state: State, shown: boolean)
    state.screen = shown and "version" or "list"
end

function M.toggle_technical(state: State)
    state.governed.technical = not state.governed.technical
end

function M.technical(state: State): boolean
    return state.governed.technical
end

type Line = {label: string, value: string}

-- What a person reads about one governed version: its status, where it came
-- from and how far its install has come. Technical words stay in details.
function M.version_lines(state: State, row: Row): {Line}
    local lines: {Line} = {{label = "Status", value = row.status}, {label = "Source", value = row.source}}
    if row.update then lines[#lines + 1] = {label = "Newer", value = row.update .. " is shared with this bee"} end
    local plan = governed.selected(state.governed)
    if row.available_key then
        for _, item in ipairs(state.governed.available) do
            if governed.available_key(item) == row.available_key then plan = governed.staged_plan(state.governed, item) end
        end
    end
    local verdict = governed.verdict(state.governed, plan)
    if plan then
        local checks = "Not checked yet"
        if verdict == "ready" then checks = "Passed"
        elseif verdict == "blocked" then
            local report = state.governed.report
            local count = report and #report.diagnostics or 0
            checks = "Fails " .. tostring(count) .. (count == 1 and " check" or " checks")
        elseif verdict == "unreadable" then checks = "Can't be trusted; try Refresh" end
        lines[#lines + 1] = {label = "Checks", value = checks}
        local changes = state.governed.changes
        if changes and state.governed.review_key == governed.key(plan) then
            lines[#lines + 1] = {label = "Changes", value = tostring(#changes.added) .. " added · "
                .. tostring(#changes.changed) .. " changed · " .. tostring(#changes.removed) .. " removed"}
        end
    end
    if row.status == M.STATUS_WAITING then
        lines[#lines + 1] = {label = "Next", value = "Approve it in Needs you"}
    elseif row.status == M.STATUS_INSTALLING then
        lines[#lines + 1] = {label = "Next", value = "Approved; installing now"}
    end
    return lines
end

return M
