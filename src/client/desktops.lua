-- MIT. Supervisor-local resources for retained desktops over existing hosts.
local process = require("process")
local tty = require("tty")
local security = require("security")
local binding = require("binding")
local contract = require("contract")
local lifecycle = require("lifecycle")
local attachments = require("attachments")
type Selection = {host: string, workspace_id: string, database: string, width: integer, height: integer,
    application: string?, options: unknown}
type Desktop = {pid: string, database: string, view: tty.Viewport, grants: attachments.State,
    selection: Selection, scope: security.Scope}
type State = {desktops: {[string]: Desktop}}
local M = {}
function M.new(): State
    local desktops: {[string]: Desktop} = {}
    return {desktops = desktops}
end
local function spawn(view: tty.Viewport, selected: Selection, scope: security.Scope): (string?, string?)
    local grant, grant_error = view:grant()
    if not grant then return nil, tostring(grant_error) end
    local bootstrap = assert(lifecycle.bootstrap(selected.options))
    local owner = tostring(process.pid())
    local pid, spawn_error = process.with_options({terminal = grant})
        :with_context({["bee.client_owner"] = owner}):with_scope(scope):spawn_monitored(
            "bee.client:main", "bee:workers", owner, selected.host, selected.workspace_id, selected.database,
            selected.application, {version = 1, quit_mode = bootstrap.quit_mode,
                desktop_id = bootstrap.desktop_id, legacy_desktop = bootstrap.legacy_desktop, arguments = bootstrap.arguments,
                fullscreen = bootstrap.fullscreen, secondary_application = bootstrap.secondary_application,
                inherit_appearance = bootstrap.inherit_appearance, node_defaults = bootstrap.node_defaults, hive_supervisor = bootstrap.hive_supervisor})
    if not pid then return nil, tostring(spawn_error) end
    return tostring(pid), nil
end

-- The calling supervisor selects the host, exact store and scope. This library
-- neither creates a workspace host nor admits physical recipients. A returned
-- PID means spawned; the caller must authenticate readiness and arrange host
-- admission before describing the desktop as ready.
function M.start(state: State, selected: Selection, scope: security.Scope): (Desktop?, string?)
    local database = binding.database("client", selected.database)
    local bootstrap = lifecycle.bootstrap(selected.options)
    local host = contract.text(selected.host, 160)
    if not database or not bootstrap or not host or host == ""
        or not contract.workspace_id(selected.workspace_id) then return nil, "Invalid desktop selection" end
    if selected.width < 1 or selected.width > 4096 or selected.height < 1 or selected.height > 4096 then
        return nil, "Invalid desktop dimensions"
    end
    local reservation = bootstrap.desktop_id and (database .. "#" .. bootstrap.desktop_id) or database
    if state.desktops[reservation] then return nil, "Desktop store already has a retained owner" end
    local view, view_error = tty.viewport({width = selected.width, height = selected.height})
    if not view then return nil, tostring(view_error) end
    local launch: Selection = {host = host, workspace_id = selected.workspace_id, database = database,
        width = selected.width, height = selected.height, application = selected.application, options = selected.options}
    local pid, spawn_error = spawn(view, launch, scope)
    if not pid then view:close(); return nil, tostring(spawn_error) end
    local desktop: Desktop = {pid = pid, database = database, view = view, grants = attachments.new(view),
        selection = launch, scope = scope}
    state.desktops[reservation] = desktop
    return desktop
end
-- The old process has exited and its host admission has been revoked. Keep the
-- supervisor's viewport and attachments while issuing a fresh terminal grant.
function M.restart(state: State, desktop: Desktop): (string?, string?)
    local held = false
    for _, candidate in pairs(state.desktops) do if candidate == desktop then held = true; break end end
    if not held then return nil, "Desktop is no longer retained" end
    local selected = desktop.selection
    local bootstrap = lifecycle.bootstrap(selected.options)
    if not bootstrap then return nil, "Invalid retained desktop selection" end
    local options: unknown = {version = 1, quit_mode = bootstrap.quit_mode, desktop_id = bootstrap.desktop_id,
        node_defaults = bootstrap.node_defaults, hive_supervisor = bootstrap.hive_supervisor}
    local resumed: Selection = {host = selected.host, workspace_id = selected.workspace_id,
        database = selected.database, width = selected.width, height = selected.height,
        application = nil, options = options}
    local pid, err = spawn(desktop.view, resumed, desktop.scope)
    if not pid then return nil, err end
    desktop.pid, desktop.selection = pid, resumed
    return pid, nil
end
function M.retire(state: State, desktop: Desktop)
    for key, candidate in pairs(state.desktops) do
        if candidate == desktop then
            desktop.view:close()
            state.desktops[key] = nil
            return
        end
    end
end

-- Only actual process events belong here. Physical-display EXIT does not match
-- the desktop PID and cannot release its viewport or database reservation.
function M.exited(state: State, event: process.Event): boolean
    if event.kind ~= process.event.EXIT then return false end
    for database, desktop in pairs(state.desktops) do
        if desktop.pid == tostring(event.from) then
            M.retire(state, desktop)
            return true
        end
    end
    return false
end
return M
