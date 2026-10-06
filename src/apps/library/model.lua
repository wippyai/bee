-- MIT. The Library's list model: every application and driver a person can
-- install, from three sources. Versions the agents of this bee made, versions
-- other bees of the hive shared, and Hub packages are folded into one list per
-- tab. This model reads only the models it composes; it calls nothing.
local governed = require("governed")
local hub = require("hub")
local drivers = require("drivers")
local glyphs = require("glyphs")

local M = {}

type Tab = "installed" | "shared" | "history"
-- The only words a row's status uses.
type Status = "Shared" | "Waiting for your approval" | "Installing" | "Installed" | "Update available" | "Removed"
type Origin = "governed" | "hub"
-- What a row stands for: an application or a driver Bee runs for the person,
-- the one row for Bee's own platform, a Hub package, or the collapsed Hub
-- catalog.
type RowKind = "app" | "driver" | "package" | "platform" | "section"
-- One list row. key is stable across refreshes; update names the newer version
-- an Update available row offers; component names the Hub package;
-- application is the definition that opens an installed application and
-- baseline the version a removal goes back to; removable says a Hub package
-- nothing else needs may be removed.
type Row = {key: string, origin: Origin, kind: RowKind, name: string, version: string, status: Status, update: string?,
    source: string, note: string, component: string?, available_key: string?, intent_id: string?,
    operation: string?, app: string?, application: string?, baseline: string?, removable: boolean}
-- What a row needs to say; the rest is empty.
type Spec = {key: string, origin: Origin, kind: RowKind, name: string, version: string, status: Status, source: string,
    update: string?, note: string?, component: string?, available_key: string?, intent_id: string?,
    operation: string?, app: string?, application: string?, baseline: string?, removable: boolean?}
type Selection = {installed: string?, shared: string?, history: string?, platform: string?}
type Screen = "list" | "version" | "platform"
-- A removal waits for the person's confirmation. Remove takes the application
-- off this bee; back puts the version before it in its place.
type RemovalKind = "remove" | "back"
type Removal = {kind: RemovalKind, app: string, name: string, version: string, baseline: string?}
type State = {workspace_id: string, tab: Tab, screen: Screen, selected: Selection, governed: governed.State, hub: hub.State,
    notice: string, can_open: boolean, removal: Removal?, hub_open: boolean}

M.STATUS_SHARED = "Shared"
M.STATUS_WAITING = "Waiting for your approval"
M.STATUS_INSTALLING = "Installing"
M.STATUS_INSTALLED = "Installed"
M.STATUS_UPDATE = "Update available"
M.STATUS_REMOVED = "Removed"

function M.new(workspace_id: string): State
    return {workspace_id = workspace_id, tab = "installed", screen = "list",
        selected = {installed = nil, shared = nil, history = nil, platform = nil},
        governed = governed.new(workspace_id), hub = hub.new(), notice = "", can_open = false, removal = nil, hub_open = false}
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

-- The name of the agent that made one version, when the version says it.
function M.author(state: State, node: string, name: string, release: string): string?
    for _, item in ipairs(state.governed.available) do
        if item.owner_id == node and item.source_workspace == name and item.version == release then return item.author end
    end
    return nil
end

-- What a bee is called: the name it reports, else the start of its identity.
function M.bee(state: State, node: string): string
    return state.governed.names[node] or node:sub(1, 16)
end

-- Where a version came from: this bee's own work, naming its agent when it is
-- known, or another bee of the hive.
function M.source(state: State, node: string, author: string?): string
    if node == state.governed.owner_node then
        return author and ("made by " .. author) or "made on this bee"
    end
    return "from bee " .. M.bee(state, node)
end

-- The bees other than this one that versions came from, which the Library
-- asks for names.
function M.sources(state: State): {string}
    local seen: {[string]: boolean} = {}
    local nodes: {string} = {}
    local function note(node: string)
        if node ~= state.governed.owner_node and not seen[node] and #nodes < governed.MAX_NODES then
            seen[node] = true
            nodes[#nodes + 1] = node
        end
    end
    for _, item in ipairs(state.governed.available) do note(item.owner_id) end
    for _, item in ipairs(state.governed.activations) do note(item.source_node) end
    table.sort(nodes)
    return nodes
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

-- What the person reads about a version whose install did not happen.
local ENDED: {[string]: string} = {
    expired = "Approval expired — install again",
    withdrawn = "Withdrawn — install again",
    denied = "Denied",
}
local function ended_note(item: governed.Intent): string
    return ENDED[tostring(item.outcome)] or "could not be installed"
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

local function make(spec: Spec): Row
    return {key = spec.key, origin = spec.origin, kind = spec.kind, name = spec.name, version = spec.version,
        status = spec.status, update = spec.update, source = spec.source, note = spec.note or "",
        component = spec.component, available_key = spec.available_key, intent_id = spec.intent_id,
        operation = spec.operation, app = spec.app, application = spec.application, baseline = spec.baseline,
        removable = spec.removable == true}
end

-- Whether a Bee application is a driver, by the overlay that owns it.
local function driver_owner(owner: string): boolean
    return owner:sub(1, #drivers.OWNER_PREFIX) == drivers.OWNER_PREFIX
end

-- What a version is called to the person: the title its application declares,
-- else its name spoken.
local function titled(item: governed.Intent?, name: string): string
    return item and item.title or M.title(name)
end

local function built_in(module: hub.Module): boolean
    return module.source == "builtin" or module.source == "core" or module.source == "system"
end

-- The packages Bee's platform is made of: Bee itself, what is built in, and
-- whatever only those need. They are one row, not a list of packages.
local function platform_modules(state: State): {hub.Module}
    local members: {[string]: boolean} = {}
    for _, module in ipairs(state.hub.installed) do
        if module.component == "bee/bee" or built_in(module) then members[module.component] = true end
    end
    local grew = true
    while grew do
        grew = false
        for _, module in ipairs(state.hub.installed) do
            if not members[module.component] and #module.used_by > 0 then
                local inside = true
                for _, user in ipairs(module.used_by) do if not members[user] then inside = false end end
                if inside then members[module.component] = true; grew = true end
            end
        end
    end
    local found: {hub.Module} = {}
    for _, module in ipairs(state.hub.installed) do
        if members[module.component] then found[#found + 1] = module end
    end
    table.sort(found, function(a: hub.Module, b: hub.Module): boolean return a.component < b.component end)
    return found
end

-- The platform's packages, for the screen that lists them.
function M.platform(state: State): {Row}
    local rows: {Row} = {}
    for _, module in ipairs(platform_modules(state)) do
        rows[#rows + 1] = make({key = "h:" .. module.component, origin = "hub", kind = "package", name = module.component,
            version = module.version, status = M.STATUS_INSTALLED, component = module.component,
            source = module.component == "bee/bee" and "Bee" or "built in"})
    end
    return rows
end

local function installed_rows(state: State): {Row}
    local rows: {Row} = {}
    for _, app in ipairs(apps(state)) do
        local flight, current = app.flight, app.installed
        local shown = flight or current
        if shown then
            local origin_node = (current or shown).source_node
            local row = make({key = "g:app:" .. app.name, origin = "governed",
                kind = driver_owner(app.owner) and "driver" or "app", name = titled(current or shown, app.name),
                version = shown.version, status = M.STATUS_INSTALLED,
                source = M.source(state, origin_node, M.author(state, origin_node, app.name, (current or shown).version)),
                intent_id = shown.intent_id, app = app.name, application = current and current.application or nil})
            if current and current.baseline_intent_id then
                for _, earlier in ipairs(state.governed.activations) do
                    if earlier.intent_id == current.baseline_intent_id then row.baseline = earlier.version end
                end
            end
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
    local platform = platform_modules(state)
    local inside: {[string]: boolean} = {}
    for _, module in ipairs(platform) do inside[module.component] = true end
    local titles: {[string]: string} = {}
    for _, item in ipairs(state.hub.all_catalog or {}) do
        if item.title ~= "" then titles[item.component] = item.title end
    end
    local direct: {hub.Module} = {}
    for _, module in ipairs(state.hub.installed) do
        if not inside[module.component] and module.direct then direct[#direct + 1] = module end
    end
    table.sort(direct, function(a: hub.Module, b: hub.Module): boolean return a.component < b.component end)
    for _, module in ipairs(direct) do
        local row = make({key = "h:" .. module.component, origin = "hub", kind = "package",
            name = titles[module.component] or module.component, version = module.version, status = M.STATUS_INSTALLED,
            source = "from Hub", component = module.component, removable = #module.used_by == 0})
        local candidate = updates[module.component]
        if candidate and candidate.update_available and candidate.available_version ~= "" then
            row.status, row.update = M.STATUS_UPDATE, candidate.available_version
        end
        rows[#rows + 1] = row
    end
    if #platform > 0 then
        local bee: hub.Module? = nil
        for _, module in ipairs(platform) do if module.component == "bee/bee" then bee = module end end
        local row = make({key = "h:platform", origin = "hub", kind = "platform", name = "Bee",
            version = bee and bee.version or "", status = M.STATUS_INSTALLED, component = bee and "bee/bee" or nil,
            source = "built in · " .. tostring(#platform) .. (#platform == 1 and " package" or " packages")})
        local candidate = updates["bee/bee"]
        local blocked = state.hub.bee_update ~= nil and state.hub.bee_update.needs_new_binary
        if candidate and candidate.update_available and candidate.available_version ~= "" and not blocked then
            row.status, row.update = M.STATUS_UPDATE, candidate.available_version
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- Shared lists what this bee's hive made first, then, only when the person
-- opens it, the Hub catalog: Hub metadata does not say which packages Bee can
-- run as applications until they are installed.
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
    -- The newest activation of a name it is not holding, when its install did not happen.
    local last: {[string]: governed.Intent} = {}
    for _, item in ipairs(state.governed.activations) do
        if not last[item.source_workspace] then last[item.source_workspace] = item end
    end
    for _, group in ipairs(order) do
        local item = assert(best[group])
        local attempt = last[item.source_workspace]
        local spec: Spec = {key = "g:ver:" .. governed.available_key(item), origin = "governed", kind = "app",
            name = M.title(item.source_workspace), version = item.version, status = M.STATUS_SHARED,
            source = M.source(state, item.owner_id, item.author), available_key = governed.available_key(item),
            app = item.source_workspace,
            note = attempt and attempt.phase == "settled" and attempt.outcome ~= "applied" and ended_note(attempt) or nil}
        rows[#rows + 1] = make(spec)
    end
    local catalog: {hub.Item} = {}
    for _, item in ipairs(hub.visible_catalog(state.hub)) do
        if hub.component_status(state.hub, item.component) == nil then catalog[#catalog + 1] = item end
    end
    if state.hub_open then
        for _, item in ipairs(catalog) do
            rows[#rows + 1] = make({key = "h:" .. item.component, origin = "hub", kind = "package",
                name = item.title ~= "" and item.title or item.component, version = item.latest_version,
                status = M.STATUS_SHARED, source = "from Hub", component = item.component})
        end
    elseif #catalog > 0 or state.hub.total > 0 then
        rows[#rows + 1] = make({key = "h:catalog", origin = "hub", kind = "section", name = "Hub catalog", version = "",
            status = M.STATUS_SHARED, source = tostring(math.max(#catalog, state.hub.total)) .. " packages · H opens"})
    end
    return rows
end

local function history_rows(state: State): {Row}
    local rows: {Row} = {}
    for _, item in ipairs(state.governed.activations) do
        if item.phase == "settled" and item.outcome ~= "uncertain" then
            local status: Status = M.STATUS_SHARED
            local note = ended_note(item)
            if item.outcome == "applied" then
                note = ""
                status = (item.intent_id == item.observed_intent_id and item.observed_outcome == "applied")
                    and M.STATUS_INSTALLED or M.STATUS_REMOVED
            end
            rows[#rows + 1] = make({key = "g:act:" .. item.intent_id, origin = "governed",
                kind = driver_owner(item.overlay_owner) and "driver" or "app", name = titled(item, item.source_workspace),
                version = item.version, status = status,
                source = M.source(state, item.source_node, M.author(state, item.source_node, item.source_workspace, item.version)),
                note = note, intent_id = item.intent_id, app = item.source_workspace})
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
        rows[#rows + 1] = make({key = "h:op:" .. operation.digest, origin = "hub", kind = "package", name = operation.component,
            version = type(requested) == "string" and requested or "", status = status, source = "from Hub", note = note,
            component = operation.component, operation = operation.digest})
    end
    return rows
end

function M.rows(state: State, tab: Tab?): {Row}
    local shown = tab or state.tab
    if shown == "installed" then return installed_rows(state) end
    if shown == "shared" then return shared_rows(state) end
    return history_rows(state)
end

-- The header's summary: how many applications and packages this bee holds
-- installed, leaving out installs still waiting or on their way, and how many
-- others it could install.
function M.summary(state: State): string
    local shared, installed = 0, 0
    for _, row in ipairs(shared_rows(state)) do if row.kind ~= "section" then shared = shared + 1 end end
    for _, row in ipairs(installed_rows(state)) do
        if row.status == M.STATUS_INSTALLED or row.status == M.STATUS_UPDATE then installed = installed + 1 end
    end
    return tostring(installed) .. " installed · " .. tostring(shared) .. " shared"
end

-- The rows the person is choosing among: the platform's packages on its
-- screen, else the tab's list.
function M.listed(state: State): {Row}
    if state.screen == "platform" then return M.platform(state) end
    return M.rows(state)
end

local function slot(state: State): string
    return state.screen == "platform" and "platform" or state.tab
end

function M.selected_row(state: State): Row?
    local rows = M.listed(state)
    local key = (state.selected :: {[string]: string?})[slot(state)]
    for _, row in ipairs(rows) do if row.key == key then return row end end
    return rows[1]
end

function M.select(state: State, key: string)
    (state.selected :: {[string]: string?})[slot(state)] = key
    state.notice = ""
end

-- Whether a row is a Hub package nothing else needs, which the person may remove.
function M.can_remove_package(row: Row?): boolean
    return row ~= nil and row.origin == "hub" and row.kind == "package" and row.removable
end

function M.move(state: State, delta: integer)
    local rows = M.listed(state)
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

-- The platform screen lists the packages the one Bee row stands for.
function M.show_platform(state: State, shown: boolean)
    state.screen = shown and "platform" or "list"
end

-- The glyph a status goes by.
function M.status_glyph(status: Status): string
    if status == M.STATUS_INSTALLED then return glyphs.installed end
    if status == M.STATUS_UPDATE then return glyphs.update end
    if status == M.STATUS_WAITING then return glyphs.waiting end
    if status == M.STATUS_INSTALLING then return glyphs.installing end
    if status == M.STATUS_REMOVED then return glyphs.removed end
    return glyphs.hive
end

-- The glyph a row's name carries.
function M.kind_glyph(kind: RowKind): string
    if kind == "driver" then return glyphs.driver end
    if kind == "app" then return glyphs.app end
    return glyphs.package
end

-- Whether a row can be removed: any installed application.
function M.can_remove(row: Row?): boolean
    return row ~= nil and row.origin == "governed" and row.app ~= nil
        and (row.status == M.STATUS_INSTALLED or row.status == M.STATUS_UPDATE)
end

-- Whether an installed application has an earlier version to go back to.
function M.can_go_back(row: Row?): boolean
    return M.can_remove(row) and row ~= nil and row.baseline ~= nil
end

-- ask_remove opens the confirmation for removing the row's application or,
-- with kind back, for going back to its earlier version.
function M.ask_remove(state: State, row: Row?, kind: RemovalKind?): boolean
    local asked = kind or "remove"
    if not row or not row.app then return false end
    if asked == "remove" and not M.can_remove(row) then return false end
    if asked == "back" and not M.can_go_back(row) then return false end
    state.removal = {kind = asked, app = row.app, name = row.name, version = row.version, baseline = row.baseline}
    return true
end

function M.cancel_remove(state: State)
    state.removal = nil
end

-- What the confirmation tells the person: what goes, what stays.
function M.removal_lines(removal: Removal): {string}
    if removal.kind == "remove" then
        return {"Remove " .. removal.name .. " " .. removal.version .. "?",
            removal.name .. ", its permissions and its place in the menus are taken off this bee.",
            "Anything " .. removal.name .. " saved in its databases is kept; nothing is deleted.",
            "Installing " .. removal.name .. " again finds it as it was."}
    end
    return {"Go back to " .. removal.name .. " " .. tostring(removal.baseline) .. "?",
        removal.name .. " " .. removal.version .. " is removed and " .. removal.name .. " goes back to "
            .. tostring(removal.baseline) .. ", the version before it.",
        "Whatever " .. removal.name .. " saved stays where it is.",
        "If this version changed its saved data, going back stops and says so."}
end

function M.toggle_technical(state: State)
    state.governed.technical = not state.governed.technical
end

type Line = {label: string, value: string}

-- What a person reads about one governed version: its status, where it came
-- from and how far its install has come. Technical words stay in details.
function M.version_lines(state: State, row: Row): {Line}
    local lines: {Line} = {{label = "Status", value = M.status_glyph(row.status) .. " " .. row.status}, {label = "Source", value = row.source}}
    if row.update then lines[#lines + 1] = {label = "Newer", value = row.update .. " is shared with this bee"} end
    for _, item in ipairs(state.governed.available) do
        if governed.available_key(item) == row.available_key and item.author and not row.source:find("made by", 1, true) then
            lines[#lines + 1] = {label = "Made by", value = item.author}
        end
    end
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
