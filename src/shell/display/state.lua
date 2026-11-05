-- MIT. One display's state: the node and desktop it shows, what it knows of
-- that node, the windows it places and the overlays open over them, with the
-- window operations the display's parts share. Scenes and window orders are
-- kept per node and desktop, so returning to a node or desktop finds its
-- windows where this display left them.
local tty = require("tty")
local channel = require("channel")
local appearance = require("appearance")
local client = require("client")
local model = require("model")
local layout = require("layout")
local menu = require("menu")
local dialog = require("dialog")
local title_editor = require("title_editor")
local copy = require("copy")
local workspace_menu = require("workspace_menu")
local membership = require("membership")
local render = require("render")
local part_handover = require("part_handover")
local jobs = require("jobs")
local M = {}
type Result = part_handover.Result
type Launch = part_handover.Launch
type SavedWindow = part_handover.SavedWindow
type Saved = part_handover.Saved
type Jobs = {attach_job: (string, string) -> Result, call_job: (string, {[string]: unknown}) -> Result,
    watch_job: (string, string, integer) -> Result}
type DesktopReview = {id: string, approval_id: string, node: string}
type Served = {check: membership.Check, serving: boolean}
-- themed is set once the display knows its node's appearance; until then it
-- shows the loader, so no default theme flashes before the node's.
-- catalog_problem is why the node's app list is out of date, shown in the
-- status line until it refreshes.
-- pending_launch is the command the display opens once it knows the node;
-- full holds the app instances to show full-pane when they come.
-- Windows the display opened take the keyboard once they arrive
-- (focus_pending). While the person works in a full-pane window, a window
-- another display opened joins without it. Windows that ask for the person
-- arrive beneath the window the person types in, and take the keyboard only
-- when no window holds it (attention_pending).
-- app_dialogs holds the dialogs apps ask, by app instance; the display shows
-- those of the apps on its desktop, one at a time.
-- supervisor is the node's Hive supervisor; its exit means the node stopped,
-- while the owner alone exiting means the node service restarts.
-- revision is the last node event applied. Until a watch snapshot is
-- applied (synced), events wait in pending and replay after it.
-- welcomed is set once the first desktop is shown; only then does an empty
-- desktop open the Start panel.
-- notice explains a change the display made on its own; it shows after the
-- next connection until the next key or click (noticed).
-- attaching holds the apps the display is attaching, so it attaches each app
-- once however many reasons it has to.
-- origin is the node the display started on; another node's desktops carry
-- its name on the bar.
type State = {
    target: string, origin: string, surface: tty.Surface, width: integer, height: integer,
    preferences: appearance.Preferences, themed: boolean,
    catalog: {menu.Descriptor}, catalog_problem: string?,
    workspaces: {client.Workspace}, desktops: {client.Desktop}, running: {client.Instance},
    owner: string?, supervisor: string?, desktop: string,
    scenes: {[string]: model.Scene}, orders: {[string]: {string}},
    views: {[string]: tty.Viewport}, updates: {[string]: channel.Channel}, contents: {[string]: render.Content},
    revisions: {[string]: integer}, presented_revisions: {[string]: integer}, presented_focus: string,
    sizes: {[string]: string}, attaching: {[string]: boolean},
    status: string, start: menu.State?, editor: title_editor.State?, modal: dialog.State?,
    desktop_review: DesktopReview?, pending_launch: Launch?, full: {[string]: boolean},
    focus_pending: {[string]: boolean}, attention_pending: {[string]: boolean},
    alerts: {[string]: client.Alert}, alert_popup: boolean, alert_fade: channel.Channel?,
    app_dialogs: {[string]: client.Dialog}, clip: copy.Controller, workspaces_open: workspace_menu.Menu?,
    capture: layout.Capture?, preview: model.Rect?, tab_hits: {render.TabHit}, stopped: string?,
    results: channel.Channel<Result>, served: channel.Channel<Served>, hive: membership.Membership, jobs: Jobs,
    revision: integer, synced: boolean, pending: {client.Event}, pending_from: {string},
    generation: integer, welcomed: boolean, notice: string?, noticed: boolean,
}

M.APP_DIALOG = "app:"

-- new is the state of a display of target on surface; saved is the handover
-- of an upgraded predecessor, whose windows' viewports it reattaches.
function M.new(target: string, saved: Saved?, launch: Launch?, surface: tty.Surface, width: integer, height: integer): State
    local results: channel.Channel<Result> = channel.new(16)
    local served: channel.Channel<Served> = channel.new(16)
    local state: State
    local work = jobs.new(function(): string return state.target end, results)
    state = {
        target = target, origin = saved and saved.origin or target, surface = surface, width = width, height = height,
        preferences = saved and saved.appearance or appearance.defaults(), themed = saved ~= nil and saved.appearance ~= nil,
        catalog = {}, workspaces = {}, desktops = {}, running = {},
        owner = saved and saved.owner or nil, supervisor = saved and saved.supervisor or nil,
        desktop = saved and saved.desktop or "",
        scenes = saved and saved.scenes or {}, orders = saved and saved.orders or {},
        views = {}, updates = {}, contents = {}, revisions = {}, presented_revisions = {}, presented_focus = "",
        sizes = {}, attaching = {}, status = "Connecting to " .. target .. "…", pending_launch = launch, full = {},
        focus_pending = {}, attention_pending = {}, alerts = {}, alert_popup = true, app_dialogs = {},
        clip = copy.new(), tab_hits = {}, results = results, served = served, hive = membership.new(),
        jobs = work,
        revision = 0, synced = false, pending = {}, pending_from = {}, generation = 0,
        welcomed = saved ~= nil and saved.welcomed == true, noticed = false,
    }
    if saved then
        for _, item in ipairs(saved.windows) do
            local view, err = tty.attach(item.handle)
            if view then
                state.views[item.id] = view
                state.updates[item.id] = assert(view:updates())
                M.refresh(state, item.id)
            else
                state.status = "A window was lost across the upgrade: " .. tostring(err)
            end
        end
    end
    return state
end

-- handover is what the display gives the new code on an upgrade.
function M.handover(state: State): Saved
    local windows: {SavedWindow} = {}
    for id, view in pairs(state.views) do windows[#windows + 1] = {id = id, handle = view:handle()} end
    return {target = state.target, origin = state.origin, owner = state.owner, supervisor = state.supervisor,
        desktop = state.desktop, scenes = state.scenes, orders = state.orders, windows = windows,
        welcomed = state.welcomed, appearance = state.preferences}
end

local function place(state: State): string return state.target .. "/" .. state.desktop end

function M.scene(state: State): model.Scene
    local value = state.scenes[place(state)]
    if not value then
        value = model.new(state.width, state.height)
        state.scenes[place(state)] = value
    end
    if value.width ~= state.width or value.height ~= state.height then
        value = model.resize_screen(value, state.width, state.height)
        state.scenes[place(state)] = value
    end
    return value
end

function M.set_scene(state: State, value: model.Scene) state.scenes[place(state)] = value end

function M.order(state: State): {string}
    local value = state.orders[place(state)]
    if not value then
        value = {}
        state.orders[place(state)] = value
    end
    return value
end

function M.input_focus(state: State): string return M.scene(state).focus end

-- focus raises window id; the display that focuses an app sizes it.
function M.focus(state: State, id: string)
    M.set_scene(state, model.focus(M.scene(state), id))
    state.sizes[id] = nil
end

-- counts_of is how many of instances run on each desktop.
function M.counts_of(instances: {client.Instance}): {[string]: integer}
    local counts: {[string]: integer} = {}
    for _, instance in ipairs(instances) do counts[instance.desktop] = (counts[instance.desktop] or 0) + 1 end
    return counts
end

-- app_counts counts the apps each desktop runs.
function M.app_counts(state: State): {[string]: integer}
    return M.counts_of(state.running)
end

function M.current_alert(state: State): client.Alert?
    local alerts = state.alerts
    for _, instance in ipairs(state.running) do
        if instance.desktop == state.desktop and alerts[instance.id] and (alerts[instance.id].count > 0 or alerts[instance.id].failed or alerts[instance.id].installed) then return alerts[instance.id] end
    end
    for _, alert in pairs(alerts) do
        if alert.desktop == state.desktop and (alert.count > 0 or alert.failed or alert.installed) then return alert end
    end
    return nil
end

function M.desktop_label(state: State): string
    local label = workspace_menu.describe(state.desktops, state.workspaces, state.desktop) or state.target
    if state.target ~= state.origin then label = label .. " @ " .. state.target end
    return label
end

-- detach closes the display's views; windows keep their placement in the
-- desktop's scene for when the display shows it again.
function M.detach(state: State)
    for id, view in pairs(state.views) do
        view:close()
        state.views[id] = nil
    end
    state.updates, state.contents, state.sizes, state.revisions, state.attaching = {}, {}, {}, {}, {}
    copy.cancel(state.clip)
    state.capture, state.preview = nil, nil
end

function M.forget(state: State, id: string)
    local view = state.views[id]
    if view then view:close() end
    state.views[id], state.updates[id], state.contents[id], state.sizes[id], state.revisions[id], state.attaching[id] = nil, nil, nil, nil, nil, nil
    for value_desktop, value in pairs(state.scenes) do state.scenes[value_desktop] = model.remove(value, id) end
    for _, list in pairs(state.orders) do
        for index, item in ipairs(list) do
            if item == id then table.remove(list, index); break end
        end
    end
end

function M.refresh(state: State, id: string)
    local view = state.views[id]
    if not view then return end
    local revision = state.revisions[id]
    local snapshot = revision and view:snapshot(revision) or view:snapshot()
    if snapshot then
        state.contents[id] = {rows = snapshot.rows, cursor = snapshot.cursor}
        state.revisions[id] = snapshot.revision
    end
end

-- fit sizes each visible app to its window body: the display takes over an
-- app's size whenever it shows or reshapes the window.
function M.fit(state: State)
    local current = M.scene(state)
    for _, win in ipairs(model.visible(current)) do
        local view = state.views[win.id]
        if view and win.mode ~= "collapsed" then
            local body = layout.interior(win, layout.rectangle(current, win, nil, nil))
            local size = tostring(body.width) .. "x" .. tostring(body.height)
            if state.sizes[win.id] ~= size then
                state.sizes[win.id] = size
                view:resize(math.max(1, body.width), math.max(1, body.height))
            end
        end
    end
end

function M.adopt(state: State, id: string, title: string, view: tty.Viewport)
    local previous = state.views[id]
    if previous then previous:close() end
    state.views[id] = view
    state.updates[id] = assert(view:updates())
    state.sizes[id] = nil
    state.contents[id] = nil
    state.revisions[id] = nil
    local current = M.scene(state)
    local found = false
    for _, win in ipairs(current.windows) do
        if win.id == id then found = true end
    end
    if not found then
        local immersed = false
        for _, win in ipairs(current.windows) do
            if win.id == current.focus and win.mode == "fullscreen" then immersed = true end
        end
        local focused = state.focus_pending[id] == true or not immersed
        state.focus_pending[id] = nil
        if state.attention_pending[id] or state.alerts[id] then
            state.attention_pending[id] = nil
            M.set_scene(state, model.attend(model.add(current, id, id, title, nil, nil, false), id))
        else
            M.set_scene(state, model.add(current, id, id, title, nil, nil, focused))
        end
        local list = M.order(state)
        list[#list + 1] = id
    end
    if state.full[id] then
        state.full[id] = nil
        M.set_scene(state, model.toggle_fullscreen(M.scene(state), id))
    end
    M.refresh(state, id)
end

-- drags is whether window id's app declares it takes left drags.
function M.drags(state: State, id: string): boolean
    for _, instance in ipairs(state.running) do
        if instance.id == id then
            for _, app in ipairs(state.catalog) do if app.definition_id == instance.app then return app.drags == true end end
        end
    end
    return false
end

function M.descriptors(apps: {client.App}): {menu.Descriptor}
    local found: {menu.Descriptor} = {}
    for _, app in ipairs(apps) do found[#found + 1] = {definition_id = app.id, title = app.title, menus = app.menus, drags = app.drags} end
    return found
end

-- app_dialog_id names an app dialog in the modal: the instance and the
-- request it answers.
function M.app_dialog_id(item: client.Dialog): string
    return M.APP_DIALOG .. item.id .. ":" .. item.request_id
end

return M
