-- MIT. Supervisor-local resources for retained desktops over existing hosts.
local process = require("process")
local tty = require("tty")
local security = require("security")
local binding = require("binding")
local contract = require("contract")
local lifecycle = require("lifecycle")
local attachments = require("attachments")
type Desktop = {pid: string, database: string, view: tty.Viewport, grants: attachments.State}
type State = {desktops: {[string]: Desktop}}
type Selection = {host: string, workspace_id: string, database: string, width: integer, height: integer,
    application: string?, options: unknown}
local M = {}
function M.new(): State
    local desktops: {[string]: Desktop} = {}
    return {desktops = desktops}
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
    local grant, grant_error = view:grant()
    if not grant then view:close(); return nil, tostring(grant_error) end
    local owner = tostring(process.pid())
    local pid, spawn_error = process.with_options({terminal = grant})
        :with_context({["bee.client_owner"] = owner}):with_scope(scope):spawn_monitored(
            "bee.client:main", "bee:workers", owner, host, selected.workspace_id, database,
            selected.application, {version = 1, quit_mode = bootstrap.quit_mode,
                desktop_id = bootstrap.desktop_id, legacy_desktop = bootstrap.legacy_desktop, arguments = bootstrap.arguments,
                fullscreen = bootstrap.fullscreen, secondary_application = bootstrap.secondary_application,
                inherit_appearance = bootstrap.inherit_appearance, node_defaults = bootstrap.node_defaults, hive_supervisor = bootstrap.hive_supervisor})
    if not pid then view:close(); return nil, tostring(spawn_error) end
    local desktop: Desktop = {pid = tostring(pid), database = database, view = view, grants = attachments.new(view)}
    state.desktops[reservation] = desktop
    return desktop
end

-- Only actual process events belong here. Physical-display EXIT does not match
-- the desktop PID and cannot release its viewport or database reservation.
function M.exited(state: State, event: process.Event): boolean
    if event.kind ~= process.event.EXIT then return false end
    for database, desktop in pairs(state.desktops) do
        if desktop.pid == tostring(event.from) then
            desktop.view:close()
            state.desktops[database] = nil
            return true
        end
    end
    return false
end
return M
