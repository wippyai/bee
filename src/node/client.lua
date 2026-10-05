-- MIT. Calling a node: its operations over the Hive and the events it sends
-- to the displays that watch it.
local protocol = require("protocol")
local system = require("system")
local process = require("process")
local appearance = require("appearance")

-- pid is the app's process on its node.
type Instance = {id: string, app: string, title: string, desktop: string, pid: string}
-- A dialog an app asks the person: id is the app instance it belongs to;
-- the answer names request_id.
type Dialog = {id: string, request_id: string, kind: "confirm" | "text", title: string, message: string, accept: string, initial: string}
-- A menu places apps: in the Start panel or the desktop's context menu, by order.
type Menu = {id: string, title: string, location: "start" | "desktop", order: integer}
type App = {id: string, title: string, menus: {Menu}}
-- A workspace is a folder; a desktop works in one workspace and is shown on
-- at most one display.
type Workspace = {id: string, path: string, label: string}
type Desktop = {id: string, title: string, workspace: string, shown: boolean}
-- An event: "opened" and "moved" carry the instance, "closed" carries id, "appearance"
-- carries the node's appearance and "workspaces" its workspaces and desktops.
-- revision orders events after the snapshot a display applied.
-- "catalog" carries the installed apps, "title" an app's new title with its
-- id, "dialog" a dialog an app asks and "dialog_closed" the id of the app
-- whose dialog is gone.
type Event = {kind: string, revision: integer, instance: Instance?, id: string?, appearance: appearance.Preferences?,
    workspaces: {Workspace}?, desktops: {Desktop}?, apps: {App}?, title: string?, dialog: Dialog?}
-- What a node reports to list and watch; owner is the PID of the node's
-- owner process, which a watcher monitors to learn that the node stopped,
-- supervisor is the node's Hive supervisor, whose exit means the node
-- stopped; desktop is the desktop a watch chose for the display, and revision
-- is the last event the snapshot includes.
type State = {node: string, owner: string, supervisor: string, revision: integer, home: string, desktop: string?, appearance: appearance.Preferences,
    apps: {App}, running: {Instance}, workspaces: {Workspace}, desktops: {Desktop}, dialogs: {Dialog}}

local M = {}
M.EVENTS = "bee.node.event"
M.TIMEOUT = "10s"
-- DIRECTORY prefixes the hive-wide name each node's owner holds, so a display
-- finds the nodes that serve desktops.
M.DIRECTORY = "bee.node/"

-- nodes lists the hive's nodes whose owner serves desktops, the local node
-- first.
function M.nodes(): {string}
    local found: {string} = {}
    for _, member in ipairs(system.cluster.members() or {}) do
        if type(member.id) == "string" and process.registry.lookup(M.DIRECTORY .. member.id, process.registry.EVENTUAL) then
            found[#found + 1] = member.id
        end
    end
    return found
end

-- serving reports whether node's owner holds its directory name, waiting up
-- to TIMEOUT for an owner to take it. An owner's name is released when it
-- exits, so a name bound again means an owner is serving.
function M.serving(node: string): boolean
    return process.registry.lookup(M.DIRECTORY .. node, process.registry.EVENTUAL, {timeout = M.TIMEOUT}) ~= nil
end

-- call runs node operation op on node and returns its value.
function M.call(node: string, op: string, args: {[string]: unknown}): ({[string]: unknown}?, string?)
    local reply, call_error = protocol.call(node, "node." .. op, args, M.TIMEOUT)
    if not reply then return nil, call_error end
    if not reply.ok then return nil, reply.error or op .. " failed" end
    return reply.value or {}, nil
end

local function instance(value: unknown): Instance?
    if type(value) ~= "table" or type(value.id) ~= "string" or type(value.app) ~= "string"
        or type(value.title) ~= "string" or type(value.desktop) ~= "string" or type(value.pid) ~= "string" then
        return nil
    end
    return {id = value.id, app = value.app, title = value.title, desktop = value.desktop, pid = value.pid}
end

-- dialog decodes a dialog an app asks.
function M.dialog(value: unknown): Dialog?
    if type(value) ~= "table" or type(value.id) ~= "string" or type(value.request_id) ~= "string"
        or (value.kind ~= "confirm" and value.kind ~= "text") or type(value.title) ~= "string"
        or type(value.message) ~= "string" or type(value.accept) ~= "string" or type(value.initial) ~= "string" then
        return nil
    end
    return {id = value.id, request_id = value.request_id, kind = value.kind, title = value.title, message = value.message,
        accept = value.accept, initial = value.initial}
end

-- workspaces decodes a list of workspaces.
function M.workspaces(value: unknown): {Workspace}
    local found: {Workspace} = {}
    if type(value) ~= "table" then return found end
    for _, item in ipairs(value) do
        if type(item) == "table" and type(item.id) == "string" and type(item.path) == "string" and type(item.label) == "string" then
            found[#found + 1] = {id = item.id, path = item.path, label = item.label}
        end
    end
    return found
end

-- desktops decodes a list of desktops.
function M.desktops(value: unknown): {Desktop}
    local found: {Desktop} = {}
    if type(value) ~= "table" then return found end
    for _, item in ipairs(value) do
        if type(item) == "table" and type(item.id) == "string" and type(item.title) == "string" and type(item.workspace) == "string" then
            found[#found + 1] = {id = item.id, title = item.title, workspace = item.workspace, shown = item.shown == true}
        end
    end
    return found
end

-- menus decodes the menus an app is placed in.
local function menus(value: unknown): {Menu}
    local found: {Menu} = {}
    if type(value) ~= "table" then return found end
    for _, item in ipairs(value) do
        if type(item) == "table" and type(item.id) == "string" and type(item.title) == "string"
            and (item.location == "start" or item.location == "desktop") and type(item.order) == "number" and math.tointeger(item.order) then
            found[#found + 1] = {id = item.id, title = item.title, location = item.location, order = assert(math.tointeger(item.order))}
        end
    end
    return found
end

-- apps decodes an app catalog.
function M.apps(value: unknown): {App}
    local apps: {App} = {}
    if type(value) ~= "table" then return apps end
    for _, item in ipairs(value) do
        if type(item) == "table" and type(item.id) == "string" and type(item.title) == "string" then
            apps[#apps + 1] = {id = item.id, title = item.title, menus = menus(item.menus)}
        end
    end
    return apps
end

-- state decodes a list or watch reply.
function M.state(value: {[string]: unknown}): State?
    if type(value.node) ~= "string" or type(value.owner) ~= "string" or type(value.supervisor) ~= "string" or type(value.home) ~= "string"
        or type(value.revision) ~= "number" then
        return nil
    end
    local preferences = appearance.decode(value.appearance)
    if not preferences then return nil end
    local apps = M.apps(value.apps)
    local running: {Instance} = {}
    if type(value.running) == "table" then
        for _, item in ipairs(value.running) do
            local decoded = instance(item)
            if decoded then running[#running + 1] = decoded end
        end
    end
    local desktop: string? = nil
    if type(value.desktop) == "string" then desktop = value.desktop end
    local dialogs: {Dialog} = {}
    if type(value.dialogs) == "table" then
        for _, item in ipairs(value.dialogs) do
            local decoded = M.dialog(item)
            if decoded then dialogs[#dialogs + 1] = decoded end
        end
    end
    return {node = value.node, owner = value.owner, supervisor = value.supervisor, revision = math.floor(value.revision), home = value.home, desktop = desktop,
        appearance = preferences,
        apps = apps, running = running, workspaces = M.workspaces(value.workspaces), desktops = M.desktops(value.desktops),
        dialogs = dialogs}
end

-- event decodes a message received on EVENTS.
function M.event(data: unknown): Event?
    if type(data) ~= "table" or type(data.kind) ~= "string" or type(data.revision) ~= "number" then return nil end
    local event: Event = {kind = data.kind, revision = math.floor(data.revision), instance = nil, id = nil, appearance = nil,
        workspaces = nil, desktops = nil, apps = nil, title = nil, dialog = nil}
    if data.kind == "opened" or data.kind == "moved" then
        event.instance = instance(data.instance)
        if not event.instance then return nil end
        event.id = event.instance.id
    elseif data.kind == "closed" or data.kind == "dialog_closed" then
        if type(data.id) ~= "string" then return nil end
        event.id = data.id
    elseif data.kind == "title" then
        if type(data.id) ~= "string" or type(data.title) ~= "string" then return nil end
        event.id, event.title = data.id, data.title
    elseif data.kind == "dialog" then
        event.dialog = M.dialog(data.dialog)
        if not event.dialog then return nil end
        event.id = event.dialog.id
    elseif data.kind == "appearance" then
        event.appearance = appearance.decode(data.appearance)
        if not event.appearance then return nil end
    elseif data.kind == "catalog" then
        if type(data.apps) ~= "table" then return nil end
        event.apps = M.apps(data.apps)
    elseif data.kind == "workspaces" then
        if type(data.workspaces) ~= "table" or type(data.desktops) ~= "table" then return nil end
        event.workspaces, event.desktops = M.workspaces(data.workspaces), M.desktops(data.desktops)
    else
        return nil
    end
    return event
end

return M
