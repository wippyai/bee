-- MIT. The node owner's state: the installed apps and themes, the appearance,
-- the running app instances, the watching displays and the alerts, with the
-- events the owner sends those displays and the snapshot a display watches
-- from. revision counts the node's events; a display applies a snapshot and
-- the events after its revision, and a gap tells it to watch again.
local process = require("process")
local logger = require("logger")
local protocol = require("protocol")
local workspaces = require("workspaces")
local settings = require("settings")
local appearance = require("appearance")
local client = require("client")
local confirmation = require("confirmation")
local part_catalog = require("part_catalog")
local part_handover = require("part_handover")
local M = {}
type Instance = part_handover.Instance
type SavedInstance = part_handover.SavedInstance
type SavedWatcher = part_handover.SavedWatcher
type Saved = part_handover.Saved
type CatalogApp = part_catalog.CatalogApp
type Theme = part_catalog.Theme
-- catalog_problem is why the installed apps and themes could not be
-- refreshed; they are out of date while it is set. watchers maps each
-- watching display to the desktop it shows. desktop_reviews holds the
-- pending desktop close confirmations by approval.
type State = {
    node: string, home_id: string,
    installed_apps: {CatalogApp}, installed_themes: {Theme}, default_theme: string?, current: appearance.Preferences,
    catalog_problem: string?, instances: {[string]: Instance}, by_pid: {[string]: string}, watchers: {[string]: string},
    alerts: {[string]: client.Alert}, update_problems: {[string]: part_handover.UpdateProblem}, revision: integer,
    desktop_reviews: {[string]: confirmation.State},
}

-- new reads the installed apps and themes and the stored appearance of node,
-- whose own folder is workspace home_id.
function M.new(node: string, home_id: string): State
    local installed_apps, catalog_error = part_catalog.catalog()
    if not installed_apps then error("installed apps: " .. tostring(catalog_error)) end
    local installed_themes, default_theme, themes_error = part_catalog.themes()
    if not installed_themes then error("installed themes: " .. tostring(themes_error)) end
    return {node = node, home_id = home_id, installed_apps = installed_apps, installed_themes = installed_themes,
        default_theme = default_theme, current = part_catalog.stored_appearance(installed_themes, default_theme),
        instances = {}, by_pid = {}, watchers = {}, alerts = {}, update_problems = {}, revision = 0, desktop_reviews = {}}
end

function M.problem(state: State): string?
    local problems: {string} = {}
    if state.catalog_problem then problems[#problems + 1] = state.catalog_problem end
    for _, item in pairs(state.update_problems) do problems[#problems + 1] = item.reason end
    table.sort(problems)
    return #problems > 0 and table.concat(problems, "; ") or nil
end

function M.broadcast(state: State, event: {[string]: unknown})
    state.revision = state.revision + 1
    local revision = state.revision
    event.revision = revision
    for pid, desktop_id in pairs(state.watchers) do
        local outgoing = event
        if event.kind == "catalog" then
            local desktop = workspaces.desktop(desktop_id)
            local apps, err = part_catalog.admitted(state.installed_apps, desktop and desktop.workspace_id or state.home_id)
            outgoing = {kind = "catalog", revision = revision, apps = apps or {}, problem = event.problem or err}
        end
        process.send(pid, client.EVENTS, outgoing)
    end
end
local broadcast = M.broadcast

function M.update_problem(state: State, instance: Instance, reason: string?)
    state.update_problems[instance.id] = reason and {app = instance.app,
        definition = instance.update_target or instance.definition, reason = reason} or nil
    if reason then logger:warn("Application update incomplete", {id = instance.id, app = instance.app, error = reason}) end
    broadcast(state, {kind = "catalog", apps = state.installed_apps, problem = M.problem(state)})
end

-- restyle applies the current appearance to every app and display.
local function restyle(state: State)
    for _, instance in pairs(state.instances) do
        instance.view:set_page(appearance.page(state.current.theme, instance.terminal))
        process.send(instance.pid, appearance.TOPIC, {appearance = state.current})
    end
    broadcast(state, {kind = "appearance", appearance = state.current})
end

-- shown_elsewhere reports whether a display other than caller shows desktop.
function M.shown_elsewhere(state: State, desktop: string, caller: string): boolean
    for pid, shown in pairs(state.watchers) do
        if shown == desktop and pid ~= caller then return true end
    end
    return false
end

-- workspace_catalog lists the workspaces and the desktops, each with the
-- workspace it works in and whether a display shows it.
function M.workspace_catalog(state: State): ({[string]: unknown}?, string?)
    local found, err = workspaces.list()
    if not found then return nil, err end
    local desktops, desktops_error = workspaces.desktops()
    if not desktops then return nil, desktops_error end
    local listed_workspaces: {{[string]: unknown}} = {}
    for _, workspace in ipairs(found) do
        listed_workspaces[#listed_workspaces + 1] = {id = workspace.id, path = workspace.path, label = workspace.label}
    end
    local listed_desktops: {{[string]: unknown}} = {}
    for _, desktop in ipairs(desktops) do
        listed_desktops[#listed_desktops + 1] = {id = desktop.id, title = desktop.title, workspace = desktop.workspace_id,
            shown = M.shown_elsewhere(state, desktop.id, "")}
    end
    return {workspaces = listed_workspaces, desktops = listed_desktops}, nil
end

function M.announce_workspaces(state: State)
    local listed, err = M.workspace_catalog(state)
    if listed then broadcast(state, {kind = "workspaces", workspaces = listed.workspaces, desktops = listed.desktops})
    else logger:warn("Workspace catalog unavailable", {error = err}) end
end

-- dialogs lists the dialogs apps wait on, for a display that starts watching.
local function dialogs(state: State): {{[string]: unknown}}
    local found: {{[string]: unknown}} = {}
    for _, instance in pairs(state.instances) do
        local dialog = part_handover.dialog_of(instance)
        if dialog then found[#found + 1] = dialog end
    end
    table.sort(found, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return found
end

-- snapshot is the node's state as caller, a watching display, sees it.
function M.snapshot(state: State, caller: string?): {[string]: unknown}
    local running: {{[string]: unknown}} = {}
    for _, instance in pairs(state.instances) do running[#running + 1] = part_handover.describe(instance) end
    table.sort(running, function(a, b) return tostring(a.id) < tostring(b.id) end)
    local listed = M.workspace_catalog(state) or {}
    local watched = caller and state.watchers[caller]
    local desktop = watched and workspaces.desktop(watched) or nil
    local visible_apps, visible_error = part_catalog.admitted(state.installed_apps, desktop and desktop.workspace_id or state.home_id)
    local pending_alerts: {client.Alert} = {}
    for _, alert in pairs(state.alerts) do if alert.count > 0 or alert.failed or alert.installed then pending_alerts[#pending_alerts + 1] = alert end end
    return {node = state.node, owner = tostring(process.pid()), supervisor = protocol.supervisor_pid() or "",
        revision = state.revision, home = state.home_id, appearance = state.current, running = running,
        apps = visible_apps or {}, workspaces = listed.workspaces, desktops = listed.desktops, dialogs = dialogs(state), alerts = pending_alerts,
        problem = visible_error or M.problem(state)}
end

function M.theme_list(state: State): protocol.Reply
    local listed: {{[string]: unknown}} = {}
    for _, item in ipairs(state.installed_themes) do listed[#listed + 1] = item end
    return protocol.ok({themes = listed, current = state.current.theme.id, backgrounds = appearance.backgrounds()})
end

-- set_appearance stores the theme, background and taskbar style given and
-- restyles every app viewport, app and display.
function M.set_appearance(state: State, args: {[string]: unknown}): protocol.Reply
    local current = state.current
    local next_value: appearance.Preferences = {theme = current.theme, background = current.background, taskbar = current.taskbar}
    if args.theme ~= nil then
        if type(args.theme) ~= "string" then return protocol.fail("theme must be a theme id") end
        local chosen: appearance.Theme? = nil
        for _, item in ipairs(state.installed_themes) do
            if item.id == args.theme then chosen = item end
        end
        if not chosen then return protocol.fail("theme " .. args.theme .. " is not installed") end
        next_value.theme = chosen
    end
    if args.background ~= nil then
        if type(args.background) ~= "string" or not appearance.background_known(args.background) then
            return protocol.fail("unknown background " .. tostring(args.background))
        end
        next_value.background = args.background
    end
    if args.taskbar ~= nil then
        if args.taskbar ~= "labels" and args.taskbar ~= "icons" then return protocol.fail("taskbar must be labels or icons") end
        next_value.taskbar = tostring(args.taskbar)
    end
    local done, store_error = settings.set({theme = next_value.theme.id, background = next_value.background, taskbar = next_value.taskbar})
    if not done then return protocol.fail("store appearance: " .. tostring(store_error)) end
    state.current = next_value
    restyle(state)
    return protocol.ok({appearance = state.current})
end

-- refresh reads the installed apps and themes after a registry change,
-- announces a changed app catalog and restyles with a changed theme.
function M.refresh(state: State)
    local apps, apps_error = part_catalog.catalog()
    local found_themes, found_default, themes_failure = part_catalog.themes()
    if not apps or not found_themes then
        local reason = "App list is out of date: " .. tostring(apps_error or themes_failure)
        logger:error("Installed apps and themes not refreshed", {error = reason})
        if state.catalog_problem ~= reason then
            state.catalog_problem = reason
            broadcast(state, {kind = "catalog", apps = state.installed_apps, problem = M.problem(state)})
        end
        return
    end
    state.installed_apps = apps
    state.catalog_problem = nil
    broadcast(state, {kind = "catalog", apps = apps, problem = M.problem(state)})
    state.installed_themes, state.default_theme = found_themes, found_default
    local next_value = part_catalog.stored_appearance(state.installed_themes, state.default_theme)
    if not part_catalog.same_palette(next_value.theme, state.current.theme) then
        state.current = next_value
        restyle(state)
    end
end

-- handover is what the owner gives its new code on an upgrade.
function M.handover(state: State): Saved
    local saved_instances: {SavedInstance} = {}
    for _, instance in pairs(state.instances) do
        saved_instances[#saved_instances + 1] = {review = instance.review, id = instance.id, app = instance.app, title = instance.title,
            desktop = instance.desktop, workspace = instance.workspace, handle = instance.view:handle(), pid = instance.pid, terminal = instance.terminal,
            execution_id = instance.execution_id, token = instance.token, negotiate = instance.negotiate, closing = instance.closing, dialog = instance.dialog,
            args = instance.args, resume_schema = instance.resume_schema, singleton = instance.singleton,
            revision = instance.revision, definition = instance.definition, update_target = instance.update_target,
            relaunch = instance.relaunch, alias = instance.alias, request = instance.request}
    end
    local saved_watchers: {SavedWatcher} = {}
    for pid, desktop in pairs(state.watchers) do saved_watchers[#saved_watchers + 1] = {pid = pid, desktop = desktop} end
    local saved_alerts: {client.Alert} = {}
    for _, alert in pairs(state.alerts) do saved_alerts[#saved_alerts + 1] = alert end
    return {instances = saved_instances, watchers = saved_watchers, revision = state.revision, alerts = saved_alerts, update_problems = state.update_problems}
end

return M
