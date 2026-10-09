-- MIT. The node owner: the one process that owns this node's workspaces (the
-- folders it works in), its set of desktops, its appearance and its running
-- apps. Each desktop works in one workspace; each app runs on one desktop as a
-- producer process presenting into its own viewport, started in its desktop's
-- workspace. A display shows one desktop at a time and attaches to its apps
-- one by one, owning their placement. Operations arrive only from this node's Hive supervisor,
-- which supplies the caller's authenticated PID; mounts are bound to that
-- exact PID.
--
-- An app process starts with {appearance, owner, args, workspace, desktop}:
-- the node's appearance, this owner's PID (the only sender of appearance
-- changes on appearance.TOPIC), what its opener passed, the workspace its
-- desktop works in and the desktop id.
--
-- Displays that watch the node receive its events (apps opened, moved
-- between desktops and closed, the app catalog when installed apps change,
-- appearance and workspace changes) on client.EVENTS. The owner monitors
-- watchers, knows the desktop each shows, and forgets them when they exit.
--
-- App instances are kept with their desktop, so a starting node reopens its
-- desktops' apps. The owner is upgradable: when its code changes it hands its
-- instances (with their viewport handles) and its watchers to the new code,
-- which reattaches them, so running apps and attached displays survive.
local process = require("process")
local channel = require("channel")
local system = require("system")
local registry = require("registry")
local tty = require("tty")
local uuid = require("uuid")
local logger = require("logger")
local protocol = require("protocol")
local workspaces = require("workspaces")
local settings = require("settings")
local appearance = require("appearance")
local client = require("client")
local eventbus = require("events")
local descriptor = require("descriptor")
local application = require("application")
local broker = require("broker")
local command = require("command")
local arguments = require("arguments")
local env = require("env")
local boot_gate = require("boot_gate")
local confirmation = require("confirmation")

-- terminal marks an app that renders a terminal emulator, which takes the
-- theme's terminal page colors.
-- A dialog an app asks the display to show: request_id is the owner's, the
-- app's own id comes back in its answer; closing marks the confirmation an
-- app asked for before it closes.
type Dialog = {request_id: string, client_request_id: string, kind: string, title: string, message: string,
    accept: string, initial: string, closing: boolean, target: {[string]: unknown}?, confirmation: confirmation.Pending?}
-- token is the launch token the app's broker messages carry; negotiate marks
-- an app that answers close requests; closing is the close request it is
-- answering; args are what it was opened with, kept with its checkpoint.
type Instance = {id: string, app: string, title: string, desktop: string, workspace: string, view: tty.Viewport, pid: string, terminal: boolean,
    execution_id: string, token: string, negotiate: boolean, closing: string?, dialog: Dialog?, args: {[string]: unknown}, resume_schema: string,
    singleton: boolean, revision: string?, relaunch: boolean?}
type SavedInstance = {id: string, app: string, title: string, desktop: string, workspace: string, handle: string, pid: string, terminal: boolean,
    execution_id: string, token: string, negotiate: boolean, closing: string?, dialog: Dialog?, args: {[string]: unknown}, resume_schema: string,
    singleton: boolean}
type SavedWatcher = {pid: string, desktop: string}
type Saved = {instances: {SavedInstance}, watchers: {SavedWatcher}, revision: integer, alerts: {client.Alert}}
type Definition = application.Definition

local NAME = "bee.node"
-- Bee components announce what needs the person on this event system: a
-- request waiting for a decision, or an application the person approved.
local ATTENTION = "bee.attention"
local APPROVALS_ROLE = "approvals"
local MENU_TYPE = "bee.menu"
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 80, 24

-- role_app is the installed app declaring role, the first by id.
local function role_app(role: string): string?
    local entries = registry.find({[".kind"] = "process.lua", ["meta.type"] = descriptor.TYPE})
    local found: string? = nil
    for _, entry in ipairs(entries or {}) do
        local declared = descriptor.decode(entry.id, entry.meta.application)
        if declared and declared.role == role and (found == nil or entry.id < found) then found = entry.id end
    end
    return found
end

-- words are the string arguments an open passed, in order.
local function words(app_args: {[string]: unknown}): {string}
    local found: {string} = {}
    if type(app_args.arguments) == "table" then
        for _, word in ipairs(app_args.arguments :: {unknown}) do
            if type(word) == "string" then found[#found + 1] = word end
        end
    end
    return found
end

-- menus returns the installed menus, registry entries of type MENU_TYPE whose
-- data names a title, the place the menu shows (the Start panel or the
-- desktop's context menu) and its order there, by id.
local function menus(): {[string]: {[string]: unknown}}
    local found: {[string]: {[string]: unknown}} = {}
    for _, entry in ipairs(registry.find({["meta.type"] = MENU_TYPE}) or {}) do
        local data: unknown = entry.data
        local order = type(data) == "table" and type(data.order) == "number" and math.tointeger(data.order) or nil
        if type(data) == "table" and type(data.title) == "string" and (data.location == "start" or data.location == "desktop") and order then
            found[entry.id] = {id = entry.id, title = data.title, location = data.location, order = order}
        else
            logger:warn("Menu entry names no title, location and order", {id = entry.id})
        end
    end
    return found
end

-- catalog lists the installed apps: process entries of type bee.app whose
-- meta.application declares them, each with the installed menus it names.
local function catalog(): {{[string]: unknown}}
    local installed = menus()
    local apps: {{[string]: unknown}} = {}
    for _, entry in ipairs(registry.find({[".kind"] = "process.lua", ["meta.type"] = descriptor.TYPE}) or {}) do
        local declared = descriptor.decode(entry.id, entry.meta.application)
        if declared then
            local placed: {{[string]: unknown}} = {}
            for _, id in ipairs(declared.menus) do
                local menu = installed[id]
                if menu then placed[#placed + 1] = menu
                else logger:warn("App names a menu that is not installed", {id = entry.id, menu = id}) end
            end
            apps[#apps + 1] = {id = entry.id, title = declared.title, menus = placed, singleton = declared.singleton}
        else
            logger:warn("App entry declares no valid application", {id = entry.id})
        end
    end
    table.sort(apps, function(a, b) return tostring(a.title) < tostring(b.title) end)
    return apps
end

-- themes returns the installed themes, registry entries of type
-- appearance.TYPE whose data is a palette, ordered by title, and the id of
-- the one marked meta.default.
local function themes(): ({appearance.Theme}, string?)
    local found: {appearance.Theme} = {}
    local default_id: string? = nil
    for _, entry in ipairs(registry.find({["meta.type"] = appearance.TYPE}) or {}) do
        local palette: {[string]: unknown} = {}
        local data: unknown = entry.data
        if type(data) == "table" then
            for key, value in pairs(data) do palette[key] = value end
        end
        palette.id = entry.id
        local decoded = appearance.decode_theme(palette)
        if decoded then
            found[#found + 1] = decoded
            if entry.meta.default == true then default_id = entry.id end
        else
            logger:warn("Theme entry is not a palette", {id = entry.id})
        end
    end
    table.sort(found, function(a, b) return a.title < b.title end)
    return found, default_id
end

-- stored_appearance returns the node's appearance settings: the installed
-- theme its setting names (else the default theme entry, else the built-in
-- palette), its background and its taskbar style.
local function stored_appearance(installed: {appearance.Theme}, default_id: string?): appearance.Preferences
    local defaults = appearance.defaults()
    local chosen: appearance.Theme? = nil
    local id = settings.get("theme")
    for _, item in ipairs(installed) do
        if item.id == id then chosen = item end
    end
    if not chosen then
        for _, item in ipairs(installed) do
            if item.id == default_id then chosen = item end
        end
    end
    local background = settings.get("background") or defaults.background
    if not appearance.background_known(background) then background = defaults.background end
    local taskbar = settings.get("taskbar") or defaults.taskbar
    if taskbar ~= "labels" and taskbar ~= "icons" then taskbar = defaults.taskbar end
    return {theme = chosen or defaults.theme, background = background, taskbar = taskbar}
end

-- signature identifies an app catalog, so the owner announces real changes only.
local function signature(apps: {{[string]: unknown}}): string
    local parts: {string} = {}
    for _, app in ipairs(apps) do
        local placed: {string} = {}
        for _, menu in ipairs(app.menus :: {{[string]: unknown}}) do
            placed[#placed + 1] = tostring(menu.id) .. ":" .. tostring(menu.title) .. ":" .. tostring(menu.location) .. ":" .. tostring(menu.order)
        end
        parts[#parts + 1] = tostring(app.id) .. "=" .. tostring(app.title) .. "/" .. table.concat(placed, ",")
    end
    return table.concat(parts, "\n")
end

local function same_palette(a: appearance.Theme, b: appearance.Theme): boolean
    for _, role in ipairs(appearance.ROLES) do
        if (a :: {[string]: unknown})[role] ~= (b :: {[string]: unknown})[role] then return false end
    end
    for _, role in ipairs(appearance.OPTIONAL_ROLES) do
        if (a :: {[string]: unknown})[role] ~= (b :: {[string]: unknown})[role] then return false end
    end
    return a.id == b.id and a.title == b.title
end

-- idle keeps a client's owner service without serving: an in-memory client
-- displays another node and has no desktops of its own.
local function idle()
    local events = assert(process.events())
    while true do
        local selected = channel.select({events:case_receive()})
        if not selected.ok or selected.value.kind == process.event.CANCEL then return end
    end
end

local function main(saved: unknown)
    if env.get("bee:role") == "client" then return idle() end
    local startup = assert(eventbus.subscribe("supervisor", "service.update"))
    local lifecycle = assert(process.events())
    local complete = boot_gate.wait(function(): boolean
        local selected = channel.select({startup:channel():case_receive(), lifecycle:case_receive()})
        return selected.ok and (selected.channel ~= lifecycle or selected.value.kind ~= process.event.CANCEL)
    end)
    startup:close()
    if not complete then return end
    local node = assert(system.node.id())
    -- Apps are linked to the owner: an owner that fails takes its apps with
    -- it, so the restarted owner reopens each kept app once. The owner traps
    -- links, so an app that fails only ends that app.
    assert(process.set_options({upgradable = true, trap_links = true}))
    local registered, register_error = process.registry.register(NAME)
    if not registered and process.registry.lookup(NAME, process.registry.LOCAL) ~= process.pid() then
        error("register node owner: " .. tostring(register_error))
    end
    if protocol.clustered() then
        local published, publish_error = process.registry.register(client.DIRECTORY .. node, process.pid(), process.registry.EVENTUAL)
        if not published and process.registry.lookup(client.DIRECTORY .. node, process.registry.EVENTUAL) ~= process.pid() then
            error("publish node owner: " .. tostring(publish_error))
        end
    end
    local folder = assert(system.process.cwd())
    local home, home_error = workspaces.ensure(folder, nil)
    if not home then error("register folder workspace: " .. tostring(home_error)) end
    local home_id = home.id
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    -- The bee.app messages apps send their broker, one channel per topic.
    local app_topics: {[unknown]: string} = {}
    local app_cases: {unknown} = {}
    for _, topic in ipairs(broker.TOPICS) do
        local inbox = assert(process.listen(topic, {message = true}))
        app_topics[inbox] = topic
        app_cases[#app_cases + 1] = inbox
    end
    local events = assert(process.events())
    -- The installed apps and themes, refreshed when a registry change commits.
    local registry_changes = assert(eventbus.subscribe("registry", "registry.commit")):channel()
    local attention = assert(eventbus.subscribe(ATTENTION)):channel()
    local installed_apps = catalog()
    local installed_themes, default_theme = themes()
    local current = stored_appearance(installed_themes, default_theme)
    local instances: {[string]: Instance} = {}
    local by_pid: {[string]: string} = {}
    -- watchers maps each watching display to the desktop it shows.
    local watchers: {[string]: string} = {}
    local alerts: {[string]: client.Alert} = {}

    local function describe(instance: Instance): {[string]: unknown}
        return {id = instance.id, app = instance.app, title = instance.title, desktop = instance.desktop, pid = instance.pid, execution_id = instance.execution_id}
    end

    -- dialog_of is the wire form of an instance's pending dialog.
    local function dialog_of(instance: Instance): {[string]: unknown}?
        local dialog = instance.dialog
        if not dialog then return nil end
        return {id = instance.id, request_id = dialog.request_id, kind = dialog.kind, title = dialog.title,
            message = dialog.message, accept = dialog.accept, initial = dialog.initial}
    end

    -- revision counts the node's events; a display applies a snapshot and the
    -- events after its revision, and a gap tells it to watch again.
    local revision = 0

    local function broadcast(event: {[string]: unknown})
        revision = revision + 1
        event.revision = revision
        for pid in pairs(watchers) do process.send(pid, client.EVENTS, event) end
    end

    -- restyle applies the current appearance to every app and display.
    local function restyle()
        for _, instance in pairs(instances) do
            instance.view:set_page(appearance.page(current.theme, instance.terminal))
            process.send(instance.pid, appearance.TOPIC, {appearance = current})
        end
        broadcast({kind = "appearance", appearance = current})
    end

    -- shown_elsewhere reports whether a display other than caller shows desktop.
    local function shown_elsewhere(desktop: string, caller: string): boolean
        for pid, shown in pairs(watchers) do
            if shown == desktop and pid ~= caller then return true end
        end
        return false
    end

    -- workspace_catalog lists the workspaces and the desktops, each with the
    -- workspace it works in and whether a display shows it.
    local function workspace_catalog(): ({[string]: unknown}?, string?)
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
                shown = shown_elsewhere(desktop.id, "")}
        end
        return {workspaces = listed_workspaces, desktops = listed_desktops}, nil
    end

    local function announce_workspaces()
        local listed, err = workspace_catalog()
        if listed then broadcast({kind = "workspaces", workspaces = listed.workspaces, desktops = listed.desktops})
        else logger:warn("Workspace catalog unavailable", {error = err}) end
    end

    -- dialogs lists the dialogs apps wait on, for a display that starts watching.
    local function dialogs(): {{[string]: unknown}}
        local found: {{[string]: unknown}} = {}
        for _, instance in pairs(instances) do
            local dialog = dialog_of(instance)
            if dialog then found[#found + 1] = dialog end
        end
        table.sort(found, function(a, b) return tostring(a.id) < tostring(b.id) end)
        return found
    end

    local function state(): {[string]: unknown}
        local running: {{[string]: unknown}} = {}
        for _, instance in pairs(instances) do running[#running + 1] = describe(instance) end
        table.sort(running, function(a, b) return tostring(a.id) < tostring(b.id) end)
        local listed = workspace_catalog() or {}
        local pending_alerts: {client.Alert} = {}
        for _, alert in pairs(alerts) do if alert.count > 0 then pending_alerts[#pending_alerts + 1] = alert end end
        return {node = node, owner = tostring(process.pid()), supervisor = protocol.supervisor_pid() or "",
            revision = revision, home = home_id, appearance = current, running = running,
            apps = installed_apps, workspaces = listed.workspaces, desktops = listed.desktops, dialogs = dialogs(), alerts = pending_alerts}
    end

    -- start runs app on desktop as instance id, in the desktop's workspace or
    -- the one given; a kept instance reopens under its own id in the
    -- workspace it was opened in.
    local function start(id: string, app: string, desktop_id: string, app_args: {[string]: unknown}, workspace_id: string?): (Instance?, string?)
        local definition, problem = application.definition(app)
        if not definition then return nil, problem end
        local desktop, desktop_error = workspaces.desktop(desktop_id)
        if not desktop then return nil, desktop_error end
        local workspace, workspace_error = workspaces.workspace(workspace_id or desktop.workspace_id)
        if not workspace then return nil, workspace_error end
        local view, view_error = tty.viewport({width = DEFAULT_WIDTH, height = DEFAULT_HEIGHT,
            page = appearance.page(current.theme, definition.terminal)})
        if not view then return nil, "viewport: " .. tostring(view_error) end
        local grant = assert(view:grant())
        local actor, actor_error = application.actor(workspace.id, id, definition, 1)
        if not actor then
            view:close()
            return nil, actor_error
        end
        local scope, scope_problem = application.scope(definition, workspace.id)
        if not scope then
            view:close()
            return nil, scope_problem
        end
        local owner_pid = tostring(process.pid())
        local version = assert(registry.current_version())
        local token = tostring(uuid.v7())
        local execution_id = tostring(uuid.v7())
        -- The launch carries the node's options and the bee.app launch an app
        -- built on the bee.app SDK reads; the node owner is its broker.
        local options: {[string]: unknown} = {appearance = current, owner = owner_pid, args = app_args, desktop = desktop.id,
            workspace = {id = workspace.id, path = workspace.path, label = workspace.label},
            version = 1, broker_pid = owner_pid, workspace_pid = owner_pid, workspace_id = workspace.id, instance_id = id, view_id = id,
            definition_id = definition.process, execution_generation = 1, execution_id = execution_id, definition_revision = definition.revision,
            registry_revision = version:string(), launch_token = token, resume_schema = definition.resume_schema,
            resume_state = type(app_args.resume_state) == "string" and app_args.resume_state or "", arguments = words(app_args)}
        -- The host context names the workspace; the functions an app calls
        -- authorize workspace-bound operations by it, never by the request.
        local pid, spawn_error = process.with_options({terminal = grant}):with_context({["bee.workspace_id"] = workspace.id})
            :with_actor(actor):with_scope(scope)
            :spawn_linked_monitored(definition.process, "bee:workers", options)
        if not pid then
            view:close()
            return nil, "start " .. app .. ": " .. tostring(spawn_error)
        end
        local instance: Instance = {id = id, app = app, title = definition.title, desktop = desktop.id, workspace = workspace.id,
            view = view, pid = tostring(pid),
            terminal = definition.terminal, execution_id = execution_id, token = token, negotiate = false, closing = nil, dialog = nil, args = app_args,
            resume_schema = definition.resume_schema, singleton = definition.singleton, revision = definition.revision}
        instances[id] = instance
        by_pid[instance.pid] = id
        return instance, nil
    end

    -- restore reattaches the instances and watchers an upgraded predecessor
    -- handed over; monitors belong to the process and survive the upgrade.
    local function restore(value: unknown): boolean
        if type(value) ~= "table" then return false end
        if type(value.instances) == "table" then
            for _, item in ipairs(value.instances) do
                if type(item) == "table" and type(item.id) == "string" and type(item.handle) == "string"
                    and type(item.pid) == "string" and type(item.app) == "string" and type(item.title) == "string"
                    and type(item.desktop) == "string" then
                    local view, err = tty.attach(item.handle)
                    if view then
                        local dialog: unknown = item.dialog
                        instances[item.id] = {id = item.id, app = item.app, title = item.title, desktop = item.desktop,
                            workspace = type(item.workspace) == "string" and item.workspace or "",
                            view = view, pid = item.pid, terminal = item.terminal == true,
                            execution_id = type(item.execution_id) == "string" and item.execution_id or tostring(uuid.v7()), token = type(item.token) == "string" and item.token or "", negotiate = item.negotiate == true,
                            closing = type(item.closing) == "string" and item.closing or nil,
                            dialog = type(dialog) == "table" and dialog :: Dialog or nil,
                            args = type(item.args) == "table" and item.args or {},
                            resume_schema = type(item.resume_schema) == "string" and item.resume_schema or "",
                            singleton = item.singleton == true}
                        by_pid[item.pid] = item.id
                    else
                        logger:warn("App instance lost across upgrade", {id = item.id, error = tostring(err)})
                    end
                end
            end
        end
        if type(value.alerts) == "table" then
            for _, item in ipairs(value.alerts) do
                local alert = client.alert(item)
                if alert and (instances[alert.id] or (alert.app and alert.desktop and alert.workspace)) then alerts[alert.id] = alert end
            end
        end
        if type(value.revision) == "number" then revision = math.floor(value.revision) end
        if type(value.watchers) == "table" then
            for _, item in ipairs(value.watchers) do
                if type(item) == "table" and type(item.pid) == "string" and type(item.desktop) == "string" then
                    watchers[item.pid] = item.desktop
                end
            end
        end
        return true
    end

    -- reopen starts the instances the node kept when it last ran.
    local function reopen()
        local kept, err = workspaces.instances()
        if not kept then logger:warn("Kept apps unreadable", {error = err}); return end
        for _, item in ipairs(kept) do
            local _, problem = start(item.id, item.app, item.desktop_id, item.args, item.workspace_id)
            if problem then
                logger:warn("Kept app not reopened", {id = item.id, app = item.app, error = problem})
                workspaces.forget(item.id)
            end
        end
    end

    -- node_desktops returns the node's desktops, creating the first, working
    -- in the folder the node runs in, when it has none.
    local function node_desktops(): ({workspaces.Desktop}?, string?)
        local desktops, err = workspaces.desktops()
        if not desktops then return nil, err end
        if #desktops > 0 then return desktops, nil end
        local created, create_error = workspaces.create_desktop(home_id, nil)
        if not created then return nil, create_error end
        return {created}, nil
    end

    -- free_desktop returns a desktop no display shows, creating one when every
    -- desktop is shown, so each new display starts on its own desktop.
    local function free_desktop(): (string?, string?)
        local desktops, err = node_desktops()
        if not desktops then return nil, err end
        local shown: {[string]: boolean} = {}
        for _, desktop in pairs(watchers) do shown[desktop] = true end
        for _, desktop in ipairs(desktops) do
            if not shown[desktop.id] then return desktop.id, nil end
        end
        local created, create_error = workspaces.create_desktop(home_id, nil)
        if not created then return nil, create_error end
        return created.id, nil
    end

    -- watch starts sending node events to caller and chooses the desktop it
    -- shows: the one it asks for unless another display shows that, else a
    -- free one.
    local function watch(caller: string, desktop: unknown): protocol.Reply
        local chosen: string? = nil
        if type(desktop) == "string" and workspaces.desktop(desktop) and not shown_elsewhere(desktop, caller) then
            chosen = desktop
        end
        if not chosen then
            local free, err = free_desktop()
            if not free then return protocol.fail("choose desktop: " .. tostring(err)) end
            chosen = free
        end
        if not watchers[caller] then
            local monitored, monitor_error = process.monitor(caller)
            if not monitored then return protocol.fail("watch: " .. tostring(monitor_error)) end
        end
        watchers[caller] = chosen or ""
        announce_workspaces()
        local value = state()
        value.desktop = chosen
        return protocol.ok(value)
    end

    -- leave forgets a display that stops watching this node.
    local function leave(caller: string): protocol.Reply
        if watchers[caller] then
            watchers[caller] = nil
            process.unmonitor(caller)
            announce_workspaces()
        end
        return protocol.ok({})
    end

    local function show(caller: string, desktop: unknown): protocol.Reply
        if not watchers[caller] then return protocol.fail("show needs a watching display") end
        if type(desktop) ~= "string" or not workspaces.desktop(desktop) then return protocol.fail("no such desktop") end
        if shown_elsewhere(desktop, caller) then return protocol.fail("that desktop is shown on another display") end
        watchers[caller] = desktop
        announce_workspaces()
        return protocol.ok({desktop = desktop})
    end

    -- navigate gives a running app the arguments it is opened with again.
    local function navigate(instance: Instance, given: {string})
        process.send(instance.pid, broker.NAVIGATE, {version = 1, instance_id = instance.id, view_id = instance.id,
            execution_generation = 1, launch_token = instance.token, arguments = given})
    end

    -- open starts app on desktop; attention marks an app opened to ask for the
    -- person, which displays bring forward without taking the keyboard.
    local function open(app: unknown, desktop: unknown, app_args: unknown, attention: boolean?): protocol.Reply
        if type(app) ~= "string" then return protocol.fail("open needs an app id") end
        if type(desktop) ~= "string" then return protocol.fail("open needs a desktop") end
        local opened_args: {[string]: unknown} = {}
        if app_args ~= nil then
            if type(app_args) ~= "table" then return protocol.fail("open args must be a table") end
            opened_args = app_args
        end
        -- A singleton app already running on the desktop is the one opened;
        -- the arguments it is opened with reach it as navigation.
        local definition = application.definition(app)
        if definition and definition.singleton then
            for _, running in pairs(instances) do
                if running.app == app and running.desktop == desktop then
                    local given = words(opened_args)
                    if #given > 0 then navigate(running, given) end
                    local value = describe(running)
                    value.existing = true
                    return protocol.ok(value)
                end
            end
        end
        local instance, problem = start(tostring(uuid.v7()), app, desktop, opened_args)
        if not instance then return protocol.fail(problem or "open failed") end
        local kept, keep_error = workspaces.keep({id = instance.id, desktop_id = instance.desktop, workspace_id = instance.workspace,
            app = instance.app, args = opened_args})
        if not kept then logger:warn("App instance not kept", {id = instance.id, error = keep_error}) end
        broadcast({kind = "opened", instance = describe(instance), attention = attention == true or nil})
        return protocol.ok(describe(instance))
    end

    local function attach(caller: string, id: unknown): protocol.Reply
        if type(id) ~= "string" then return protocol.fail("attach needs an instance id") end
        local instance = instances[id]
        if not instance then return protocol.fail("no running instance " .. id) end
        local ref, mount_error = instance.view:mount(caller, {observe = true, input = true, resize = true})
        if not ref then return protocol.fail("mount: " .. tostring(mount_error)) end
        local value: {[string]: unknown} = {ref = ref, title = instance.title}
        return protocol.ok(value)
    end

    local function stop(instance: Instance): protocol.Reply
        local cancelled, cancel_error = process.cancel(instance.pid)
        if not cancelled then return protocol.fail("stop " .. instance.title .. ": " .. tostring(cancel_error)) end
        return protocol.ok({id = instance.id})
    end

    -- drop_dialog forgets an instance's dialog and tells the displays.
    local function drop_dialog(instance: Instance)
        if not instance.dialog then return end
        local pending = instance.dialog.confirmation
        if pending then
            local review = confirmation.new({workspace_id = instance.workspace, origin = {app_id = instance.app, instance_id = instance.id}})
            review.pending = pending
            local canceled, err = confirmation.cancel(review)
            if not canceled then error(err) end
        end
        instance.dialog = nil
        broadcast({kind = "dialog_closed", id = instance.id})
    end

    -- show_dialog puts a dialog an app asked for to the displays.
    local function show_dialog(instance: Instance, dialog: Dialog): (boolean, string?)
        if dialog.kind == "confirm" then
            local review = confirmation.new({workspace_id = instance.workspace, origin = {app_id = instance.app, instance_id = instance.id}})
            local opened, err = confirmation.open(review, dialog.closing and "app.close" or "app.query",
                {instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app, revision = instance.revision,
                    request_id = dialog.client_request_id, title = dialog.title, message = dialog.message, target = dialog.target}, "dialog", dialog.title, dialog.message)
            if not opened then return false, err end
            dialog.confirmation = review.pending
        end
        instance.dialog = dialog
        broadcast({kind = "dialog", dialog = dialog_of(instance)})
        return true, nil
    end

    -- close stops an app; an app that negotiates its close is asked first and
    -- answers with accept, cancel or a confirmation for the person. force
    -- stops it without asking.
    local function close(id: unknown, force: unknown, expected_execution: unknown): protocol.Reply
        if type(id) ~= "string" then return protocol.fail("close needs an instance id") end
        local instance = instances[id]
        if not instance then return protocol.fail("no running instance " .. id) end
        if expected_execution ~= nil and expected_execution ~= instance.execution_id then return protocol.fail("application execution changed") end
        if force == true or not instance.negotiate then return stop(instance) end
        if not instance.closing then
            local request_id = tostring(uuid.v7())
            instance.closing = request_id
            drop_dialog(instance)
            local sent, err = process.send(instance.pid, broker.CLOSE, {version = 1, request_id = request_id, id = id, instance_id = id})
            if not sent then
                instance.closing = nil
                return protocol.fail("ask " .. instance.title .. " to close: " .. tostring(err))
            end
        end
        return protocol.ok({id = id, closing = true})
    end

    -- cancel_close tells an app its close was cancelled.
    local function cancel_close(instance: Instance)
        local request_id = instance.closing
        instance.closing = nil
        if request_id then
            process.send(instance.pid, broker.CLOSE_RESULT, {version = 1, request_id = request_id, id = instance.id,
                instance_id = instance.id, action = "cancel"})
        end
    end

    -- app_message applies a bee.app message from an app's own process; one
    -- that does not carry the instance's launch token is refused.
    local function app_message(topic: string, from: string, data: unknown)
        local id = by_pid[from]
        local instance = id and instances[id] or nil
        if not instance or not broker.authentic(data, instance.id, instance.token) then
            logger:warn("Broker message refused", {topic = topic, from = from})
            return
        end
        if topic == broker.READY then
            instance.negotiate = broker.ready(data) == true
        elseif topic == broker.TITLE then
            local title = broker.title(data)
            if title and title ~= instance.title then
                instance.title = title
                broadcast({kind = "title", id = instance.id, title = title})
            end
        elseif topic == broker.CLOSE_REPLY then
            local reply = broker.close_reply(data)
            if not reply or reply.request_id ~= instance.closing then return end
            if reply.action == "accept" then
                instance.closing = nil
                stop(instance)
            elseif reply.action == "cancel" then
                cancel_close(instance)
            else
                local shown, err = show_dialog(instance, {request_id = tostring(uuid.v7()), client_request_id = reply.request_id, kind = "confirm",
                    title = reply.title, message = reply.message, accept = reply.accept, initial = "", closing = true})
                if not shown then
                    logger:warn("Close confirmation failed", {id = instance.id, error = err})
                    cancel_close(instance)
                end
            end
        elseif topic == broker.QUERY then
            local spec = broker.query(data)
            if not spec or spec.id ~= instance.id then return end
            if instance.dialog or instance.closing then
                process.send(instance.pid, broker.QUERY_RESULT, {version = 1, request_id = spec.request_id, id = instance.id,
                    instance_id = instance.id, action = "cancel", value = "", error = "busy"})
                return
            end
            local shown, err = show_dialog(instance, {request_id = tostring(uuid.v7()), client_request_id = spec.request_id, kind = spec.kind,
                title = spec.title, message = spec.message, accept = spec.accept, initial = spec.initial, closing = false, target = spec.target})
            if not shown then
                logger:warn("Application confirmation failed", {id = instance.id, error = err})
                process.send(instance.pid, broker.QUERY_RESULT, {version = 1, request_id = spec.request_id, id = instance.id,
                    instance_id = instance.id, action = "cancel", value = "", error = "unavailable"})
            end
        elseif topic == broker.CHECKPOINT then
            local checkpoint = broker.checkpoint(data)
            if not checkpoint then return end
            local result: {[string]: unknown} = {version = 1, request_id = checkpoint.request_id, error_code = "", error = ""}
            if instance.resume_schema == "" or checkpoint.resume_schema ~= instance.resume_schema then
                result.error_code, result.error = "invalid_checkpoint", "Checkpoint does not match the application contract"
            else
                local args: {[string]: unknown} = {}
                for key, value in pairs(instance.args) do args[key] = value end
                args.resume_state = checkpoint.resume_state
                local kept, keep_error = workspaces.remember(instance.id, args)
                if kept then instance.args = args
                else result.error_code, result.error = "storage", tostring(keep_error) end
            end
            process.send(instance.pid, broker.CHECKPOINT_RESULT, result)
        elseif topic == broker.REQUEST then
            local request = broker.open(data)
            if not request then return end
            local reply = open(request.definition_id, instance.desktop, {arguments = request.arguments})
            if not reply.ok then logger:warn("App navigation failed", {from = instance.id, to = request.definition_id, error = tostring(reply.error)}) end
        end
    end

    -- stats reports this node's runtime numbers and what it runs, for a
    -- hive view that samples it while it is open.
    local function stats(): protocol.Reply
        local memory, memory_error = system.memory.stats()
        if not memory then return protocol.fail("memory statistics: " .. tostring(memory_error)) end
        local goroutines, goroutines_error = system.runtime.goroutines()
        if not goroutines then return protocol.fail("goroutines: " .. tostring(goroutines_error)) end
        local cpu_count, cpu_error = system.runtime.cpu_count()
        if not cpu_count then return protocol.fail("cpu count: " .. tostring(cpu_error)) end
        local apps = 0
        for _ in pairs(instances) do apps = apps + 1 end
        local listed = workspaces.list() or {}
        local home = workspaces.workspace(home_id)
        return protocol.ok({node = node, name = home and home.label or node, heap = memory.heap_alloc, reserved = memory.sys, gc_cycles = memory.num_gc,
            goroutines = goroutines, cpu_count = cpu_count, apps = apps, workspaces = #listed})
    end

    -- resolve_command finds the installed app a `bee NAME` command opens and
    -- the arguments it opens with.
    local function resolve_command(name: unknown, tail: unknown): protocol.Reply
        if type(name) ~= "string" then return protocol.fail("command needs a name") end
        local words_given = arguments.decode(tail)
        if not words_given then return protocol.fail("command arguments must be a list of words") end
        local installed: {[string]: boolean} = {}
        for _, app in ipairs(installed_apps) do installed[tostring(app.id)] = true end
        local launch, problem = command.resolve(name, words_given, installed)
        if not launch then return protocol.fail(problem or "Unknown Bee command: " .. name) end
        return protocol.ok({app = launch.definition_id, arguments = launch.arguments, fullscreen = launch.fullscreen})
    end

    -- answer applies a display's answer to the dialog an app waits on.
    local function answer(args: {[string]: unknown}): protocol.Reply
        local id = args.id
        if type(id) ~= "string" then return protocol.fail("answer needs an instance id") end
        local instance = instances[id]
        if not instance then return protocol.fail("no running instance " .. id) end
        local dialog = instance.dialog
        if not dialog or args.request_id ~= dialog.request_id then return protocol.fail("no such dialog for " .. id) end
        local action = args.action
        if action ~= "accept" and action ~= "cancel" then return protocol.fail("answer must accept or cancel") end
        local value = args.value
        if value == nil then value = "" end
        if type(value) ~= "string" or #value > 256 or value:find("%c") or (action == "cancel" and value ~= "") then
            return protocol.fail("answer value is invalid")
        end
        if dialog.confirmation then
            local review = confirmation.new({workspace_id = instance.workspace, origin = {app_id = instance.app, instance_id = instance.id}})
            review.pending = dialog.confirmation
            local confirmed: boolean
            local err: string?
            if action == "accept" then
                local gesture = args.gesture
                if gesture ~= "enter" and gesture ~= "space" and gesture ~= "click" and gesture ~= "shortcut" then return protocol.fail("answer needs its confirmed gesture") end
                confirmed, err = confirmation.accept(review, {instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app, revision = instance.revision,
                    request_id = dialog.client_request_id, title = dialog.title, message = dialog.message, target = dialog.target}, gesture)
            else confirmed, err = confirmation.cancel(review) end
            if not confirmed then return protocol.fail(err or "confirmation failed") end
            dialog.confirmation = nil
        end
        drop_dialog(instance)
        if dialog.closing then
            if action == "accept" then
                instance.closing = nil
                return stop(instance)
            end
            cancel_close(instance)
            return protocol.ok({id = id})
        end
        process.send(instance.pid, broker.QUERY_RESULT, {version = 1, request_id = dialog.client_request_id, id = id,
            instance_id = id, action = action, value = value, error = ""})
        return protocol.ok({id = id})
    end

    -- move puts a running app on another desktop; displays showing either
    -- desktop follow it.
    local function move(id: unknown, desktop: unknown): protocol.Reply
        if type(id) ~= "string" then return protocol.fail("move needs an instance id") end
        local instance = instances[id]
        if not instance then return protocol.fail("no running instance " .. id) end
        if type(desktop) ~= "string" or not workspaces.desktop(desktop) then return protocol.fail("no such desktop") end
        local moved, err = workspaces.move_instance(id, desktop)
        if not moved then return protocol.fail(err or "app not moved") end
        instance.desktop = desktop
        broadcast({kind = "moved", instance = describe(instance)})
        return protocol.ok(describe(instance))
    end

    local function theme_list(): protocol.Reply
        local listed: {{[string]: unknown}} = {}
        for _, item in ipairs(installed_themes) do listed[#listed + 1] = item end
        return protocol.ok({themes = listed, current = current.theme.id, backgrounds = appearance.backgrounds()})
    end

    -- set_appearance stores the theme, background and taskbar style given and
    -- restyles every app viewport, app and display.
    local function set_appearance(args: {[string]: unknown}): protocol.Reply
        local next_value: appearance.Preferences = {theme = current.theme, background = current.background, taskbar = current.taskbar}
        if args.theme ~= nil then
            if type(args.theme) ~= "string" then return protocol.fail("theme must be a theme id") end
            local chosen: appearance.Theme? = nil
            for _, item in ipairs(installed_themes) do
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
        current = next_value
        restyle()
        return protocol.ok({appearance = current})
    end

    local function add_workspace(path: unknown, label: unknown): protocol.Reply
        if type(path) ~= "string" or not workspaces.absolute(path) then return protocol.fail("a workspace needs an absolute path") end
        local name: string? = nil
        if type(label) == "string" and label ~= "" then name = label end
        local workspace, err = workspaces.ensure(path, name)
        if not workspace then return protocol.fail(err or "workspace not added") end
        announce_workspaces()
        return protocol.ok({workspace = workspace.id})
    end

    -- remove_workspace forgets a workspace no desktop works in; the folder the
    -- node runs in stays.
    local function remove_workspace(id: unknown): protocol.Reply
        if type(id) ~= "string" or not workspaces.workspace(id) then return protocol.fail("no such workspace") end
        if id == home_id then return protocol.fail("the node's own folder stays a workspace") end
        for _, desktop in ipairs(workspaces.desktops() or {}) do
            if desktop.workspace_id == id then return protocol.fail(desktop.title .. " works in that workspace") end
        end
        local removed, err = workspaces.remove_workspace(id)
        if not removed then return protocol.fail(err or "workspace not removed") end
        announce_workspaces()
        return protocol.ok({workspace = id})
    end

    -- create_desktop adds a desktop working in workspace_id, or in the folder
    -- the node runs in.
    local function create_desktop(workspace_id: unknown, title: unknown): protocol.Reply
        local folder = home_id
        if workspace_id ~= nil then
            if type(workspace_id) ~= "string" or not workspaces.workspace(workspace_id) then return protocol.fail("no such workspace") end
            folder = workspace_id
        end
        local name: string? = nil
        if type(title) == "string" and title ~= "" then name = title end
        local desktop, err = workspaces.create_desktop(folder, name)
        if not desktop then return protocol.fail(err or "desktop not added") end
        announce_workspaces()
        return protocol.ok({desktop = desktop.id, title = desktop.title})
    end

    -- use_workspace makes desktop id work in workspace_id; apps opened on it
    -- from then on start there.
    local function use_workspace(id: unknown, workspace_id: unknown): protocol.Reply
        if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
        if type(workspace_id) ~= "string" or not workspaces.workspace(workspace_id) then return protocol.fail("no such workspace") end
        local used, err = workspaces.use_workspace(id, workspace_id)
        if not used then return protocol.fail(err or "workspace not used") end
        announce_workspaces()
        return protocol.ok({desktop = id, workspace = workspace_id})
    end

    local function rename_desktop(id: unknown, title: unknown): protocol.Reply
        if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
        if type(title) ~= "string" or title == "" then return protocol.fail("a desktop needs a title") end
        local renamed, err = workspaces.rename_desktop(id, title)
        if not renamed then return protocol.fail(err or "desktop not renamed") end
        announce_workspaces()
        return protocol.ok({desktop = id, title = title})
    end

    -- close_desktop stops a desktop's apps and removes it; a desktop a display
    -- shows stays.
    local desktop_reviews: {[string]: confirmation.State} = {}
    local function desktop_target(id: string): {[string]: unknown}?
        local desktop = workspaces.desktop(id)
        if not desktop then return nil end
        local apps: {{[string]: unknown}} = {}
        for _, instance in pairs(instances) do
            if instance.desktop == id then apps[#apps + 1] = {instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app, revision = instance.revision} end
        end
        table.sort(apps, function(a, b) return tostring(a.instance_id) < tostring(b.instance_id) end)
        return {desktop_id = id, workspace_id = desktop.workspace_id, title = desktop.title, apps = apps}
    end
    local function desktop_confirmation(args: {[string]: unknown}): protocol.Reply
        local id = args.id
        if type(id) ~= "string" then return protocol.fail("confirmation needs a desktop") end
        if args.operation == "cancel" then
            local review = type(args.approval_id) == "string" and desktop_reviews[args.approval_id] or nil
            if not review then return protocol.fail("no such desktop confirmation") end
            local canceled, err = confirmation.cancel(review)
            if not canceled then return protocol.fail(err or "withdrawal failed") end
            desktop_reviews[tostring(args.approval_id)] = nil
            return protocol.ok({})
        end
        local target = desktop_target(id)
        local desktop = workspaces.desktop(id)
        if not target or not desktop then return protocol.fail("no such desktop") end
        local review = confirmation.new({workspace_id = desktop.workspace_id, origin = {app_id = "bee.shell:shell", instance_id = id}})
        local opened, err = confirmation.open(review, "desktop.close", target, "dialog", "Close desktop", "Close " .. desktop.title .. " and stop its apps?")
        if not opened then return protocol.fail(err or "confirmation failed") end
        local approval_id = assert(review.pending).view.approval_id
        desktop_reviews[tostring(approval_id)] = review
        return protocol.ok({approval_id = approval_id})
    end
    local function confirm_desktop(args: {[string]: unknown}): protocol.Reply
        local id, approval_id, gesture = args.id, args.approval_id, args.gesture
        if type(id) ~= "string" or type(approval_id) ~= "string" then return protocol.fail("confirmation identity is invalid") end
        local review, target = desktop_reviews[approval_id], desktop_target(id)
        if not review or not target then return protocol.fail("desktop confirmation is unavailable") end
        if gesture ~= "enter" and gesture ~= "space" and gesture ~= "click" then return protocol.fail("confirmation gesture is invalid") end
        local accepted, err = confirmation.accept(review, target, gesture)
        if not accepted then return protocol.fail(err or "confirmation failed") end
        desktop_reviews[approval_id] = nil
        return protocol.ok({})
    end
    local function close_desktop(id: unknown): protocol.Reply
        if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
        for _, desktop in pairs(watchers) do
            if desktop == id then return protocol.fail("a display shows that desktop") end
        end
        for _, instance in pairs(instances) do
            if instance.desktop == id then
                local cancelled, cancel_error = process.cancel(instance.pid)
                if not cancelled then return protocol.fail("stop " .. instance.title .. ": " .. tostring(cancel_error)) end
            end
        end
        local removed, err = workspaces.remove_desktop(id)
        if not removed then return protocol.fail(err or "desktop not removed") end
        announce_workspaces()
        return protocol.ok({desktop = id})
    end

    -- refresh reads the installed apps and themes after a registry change,
    -- announces a changed app catalog and restyles with a changed theme.
    local function refresh()
        local apps = catalog()
        if signature(apps) ~= signature(installed_apps) then
            installed_apps = apps
            broadcast({kind = "catalog", apps = apps})
        end
        installed_themes, default_theme = themes()
        local next_value = stored_appearance(installed_themes, default_theme)
        if not same_palette(next_value.theme, current.theme) then
            current = next_value
            restyle()
        end
    end

    -- present opens app with arguments on every desktop a display shows that
    -- works in workspace_id and asks those displays to bring it forward.
    local function present(workspace_id: string, app: string, arguments: {string}, pending: {count: integer, title: string, approval_id: string}?)
        local seen: {[string]: boolean} = {}
        for _, desktop_id in pairs(watchers) do
            if desktop_id ~= "" and not seen[desktop_id] then
                seen[desktop_id] = true
                local desktop = workspaces.desktop(desktop_id)
                if desktop and desktop.workspace_id == workspace_id then
                    local opened = open(app, desktop_id, {arguments = arguments}, true)
                    local value = opened.value
                    if opened.ok and value then
                        assert(type(value.id) == "string", "Presented app has no instance identity")
                        local alert: client.Alert? = pending and {id = value.id, count = pending.count, title = pending.title,
                            approval_id = pending.approval_id, app = app, desktop = desktop_id, workspace = workspace_id}
                        for id, previous in pairs(alerts) do
                            if previous.desktop == desktop_id and previous.app == app and id ~= value.id then alerts[id] = nil end
                        end
                        if alert then alerts[value.id] = alert end
                        broadcast({kind = "attention", id = value.id, alert = alert})
                    else logger:warn("App not presented", {app = app, desktop = desktop_id, error = opened.error}) end
                end
            end
        end
    end

    -- A request waiting for the person opens Needs you; an application the
    -- person approved opens once it is installed.
    local function attend(event: {[string]: unknown})
        local data = event.data
        if type(event.path) ~= "string" or type(data) ~= "table" then return end
        local workspace_id: string = event.path
        if event.kind == "approval.requested" then
            local inbox = role_app(APPROVALS_ROLE)
            local approval_id = type(data.approval_id) == "string" and data.approval_id or nil
            if not inbox then logger:warn("No installed app handles approvals")
            elseif approval_id then
                local count = type(data.count) == "number" and math.floor(data.count) or nil
                local title = type(data.title) == "string" and data.title or "Review request"
                present(workspace_id, inbox, {"--approval", approval_id}, count and {count = count, title = title, approval_id = approval_id} or nil)
            else present(workspace_id, inbox, {}) end
        elseif event.kind == "approval.changed" and type(data.count) == "number" then
            for id, alert in pairs(alerts) do
                local instance = instances[id]
                if alert.workspace == workspace_id or (instance and instance.workspace == workspace_id) then
                    alert.count = math.floor(data.count)
                    if type(data.approval_id) == "string" then alert.approval_id = data.approval_id end
                    if type(data.title) == "string" then alert.title = data.title end
                    broadcast({kind = "attention", id = id, alert = alert, changed = true})
                end
            end
        elseif event.kind == "application.applied" and type(data.component) == "string" then
            refresh()
            local prefix = tostring(data.component) .. ":"
            -- A window already running an earlier revision of the application
            -- restarts in place on the applied one; the others are presented.
            local running: {[string]: boolean} = {}
            for _, instance in pairs(instances) do
                if instance.workspace == workspace_id and instance.app:sub(1, #prefix) == prefix then
                    running[instance.app] = true
                    local definition = application.definition(instance.app)
                    if definition and definition.revision ~= instance.revision and not instance.relaunch then
                        instance.relaunch = true
                        local stopped = stop(instance)
                        if not stopped.ok then
                            instance.relaunch = nil
                            logger:warn("App not restarted on its applied revision", {id = instance.id, error = stopped.error})
                        end
                    end
                end
            end
            for _, app in ipairs(installed_apps) do
                local id = app.id
                if type(id) == "string" and id:sub(1, #prefix) == prefix and not running[id] then present(workspace_id, id, {}) end
            end
        end
    end

    local function handle(request: protocol.Forwarded): protocol.Reply
        local op, args = request.op, request.args
        if op == "list" then return protocol.ok(state()) end
        if op == "watch" then return watch(request.caller, args.desktop) end
        if op == "show" then return show(request.caller, args.desktop) end
        if op == "leave" then return leave(request.caller) end
        if op == "open" then return open(args.app, args.desktop, args.args) end
        if op == "attach" then return attach(request.caller, args.id) end
        if op == "close" then return close(args.id, args.force, args.execution_id) end
        if op == "answer" then return answer(args) end
        if op == "command" then return resolve_command(args.name, args.arguments) end
        if op == "stats" then return stats() end
        if op == "move" then return move(args.id, args.desktop) end
        if op == "themes" then return theme_list() end
        if op == "appearance" then return set_appearance(args) end
        if op == "workspaces" then
            local listed, err = workspace_catalog()
            if not listed then return protocol.fail(err or "workspaces unavailable") end
            return protocol.ok({node = node, home = home_id, workspaces = listed.workspaces, desktops = listed.desktops})
        end
        if op == "desktop_workspace" then return use_workspace(args.id, args.workspace) end
        if op == "workspace_add" then return add_workspace(args.path, args.label) end
        if op == "workspace_remove" then return remove_workspace(args.id) end
        if op == "desktop_create" then return create_desktop(args.workspace, args.title) end
        if op == "desktop_rename" then return rename_desktop(args.id, args.title) end
        if op == "desktop_confirmation" then return desktop_confirmation(args) end
        if op == "desktop_close" then
            if args.approval_id ~= nil then
                local confirmed = confirm_desktop(args)
                if not confirmed.ok then return confirmed end
            end
            return close_desktop(args.id)
        end
        return protocol.fail("unknown node operation " .. op)
    end

    -- exited forgets a display or an app whose process ended; problem is the
    -- error an app failed with.
    local function exited(pid: string, problem: string?)
        if watchers[pid] then
            watchers[pid] = nil
            announce_workspaces()
        end
        local id = by_pid[pid]
        if not id then return end
        by_pid[pid] = nil
        local instance = instances[id]
        if instance then drop_dialog(instance) end
        instances[id] = nil
        workspaces.forget(id)
        if instance then
            if problem and not instance.relaunch then logger:warn("App failed", {id = id, app = instance.app, error = problem}) end
            instance.view:close()
            broadcast({kind = "closed", id = id})
            if instance.relaunch then
                local restarted, restart_error = start(id, instance.app, instance.desktop, instance.args, instance.workspace)
                if not restarted then
                    logger:warn("App not restarted on its applied revision", {id = id, app = instance.app, error = restart_error})
                    return
                end
                local kept, keep_error = workspaces.keep({id = restarted.id, desktop_id = restarted.desktop,
                    workspace_id = restarted.workspace, app = restarted.app, args = restarted.args})
                if not kept then logger:warn("App instance not kept", {id = restarted.id, error = keep_error}) end
                broadcast({kind = "opened", instance = describe(restarted)})
            end
        end
    end

    local function handover(): Saved
        local saved_instances: {SavedInstance} = {}
        for _, instance in pairs(instances) do
            saved_instances[#saved_instances + 1] = {id = instance.id, app = instance.app, title = instance.title,
                desktop = instance.desktop, workspace = instance.workspace, handle = instance.view:handle(), pid = instance.pid, terminal = instance.terminal,
                execution_id = instance.execution_id, token = instance.token, negotiate = instance.negotiate, closing = instance.closing, dialog = instance.dialog,
                args = instance.args, resume_schema = instance.resume_schema, singleton = instance.singleton}
        end
        local saved_watchers: {SavedWatcher} = {}
        for pid, desktop in pairs(watchers) do saved_watchers[#saved_watchers + 1] = {pid = pid, desktop = desktop} end
        local saved_alerts: {client.Alert} = {}
        for _, alert in pairs(alerts) do saved_alerts[#saved_alerts + 1] = alert end
        return {instances = saved_instances, watchers = saved_watchers, revision = revision, alerts = saved_alerts}
    end

    if not restore(saved) then
        local desktops, desktops_error = node_desktops()
        if not desktops then error("first desktop: " .. tostring(desktops_error)) end
        reopen()
    end
    local announced, announce_error = protocol.ready(NAME)
    if not announced then logger:warn("Hive supervisor not told the node is ready", {error = announce_error}) end
    logger:info("Node ready", {node = node, folder = folder, theme = current.theme.id})
    while true do
        local cases = {requests:case_receive(), events:case_receive(), registry_changes:case_receive(), attention:case_receive()}
        for _, inbox in ipairs(app_cases) do cases[#cases + 1] = (inbox :: channel.Channel):case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then return end
        local app_topic = app_topics[selected.channel]
        if app_topic then
            local message = selected.value
            app_message(app_topic, tostring(message:from()), message:payload():data())
        elseif selected.channel == registry_changes then
            refresh()
        elseif selected.channel == attention then
            attend(selected.value)
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then
                for _, instance in pairs(instances) do instance.view:close() end
                return
            end
            if event.kind == process.event.OUTDATED then
                process.upgrade("", handover())
                return
            end
            if event.kind == process.event.EXIT or event.kind == process.event.MONITOR_DOWN or event.kind == process.event.LINK_DOWN then
                local result: unknown = event.result
                local problem: string? = nil
                if type(result) == "table" and result.error ~= nil then problem = tostring(result.error) end
                exited(tostring(event.from), problem)
            end
        else
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then
                local handled, reply = pcall(handle, request)
                if not handled then
                    logger:error("Node operation failed", {op = request.op, error = tostring(reply)})
                    reply = protocol.fail(request.op .. " failed: " .. tostring(reply))
                end
                process.send(request.caller, request.reply_topic, reply)
            else
                logger:warn("Node ignored a request that did not come from the node supervisor", {from = tostring(message:from())})
            end
        end
    end
end

return {main = main}
