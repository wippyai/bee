-- MIT. The shell: one display of a node. It shows one of the node's desktops
-- at a time and places that desktop's apps as windows it owns: placement,
-- stacking, modes and names are this display's, so two displays can show the
-- same desktop differently or different desktops altogether. Apps run on the
-- node; each window is a mount of its app's viewport. Node calls run in
-- coroutines and report back on a channel, so the shell answers input and
-- cancellation while it waits.
--
-- Keys: F1 Start menu, F3 workspaces, Alt+Tab next window, Ctrl+W close the
-- focused app, F11 full pane, Alt+F9 minimize, F12 reload, Ctrl+Q quit the
-- display (apps keep running). The mouse focuses, moves and resizes windows
-- by their frame, uses their controls, and opens context menus on a right
-- click on a window, a tab or the desktop.
--
-- The display follows the node's owner process and closes when it stops. The
-- shell is upgradable: on new code it hands its desktop and windows to the new
-- version, which reattaches their viewports and redraws.
local tty = require("tty")
local io = require("io")
local system = require("system")
local events = require("events")
local channel = require("channel")
local process = require("process")
local appearance = require("appearance")
local client = require("client")
local chrome = require("chrome")
local model = require("model")
local layout = require("layout")
local menu = require("menu")
local dialog = require("dialog")
local title_editor = require("title_editor")
local watch = require("watch")
local selection = require("selection")
local workspace_menu = require("workspace_menu")
local render = require("render")

-- generation is the connection a result belongs to; a result from an earlier
-- connection (another node, or before the owner came back) is dropped.
type Result = {kind: string, problem: string?, state: client.State?, id: string?, title: string?,
    view: tty.Viewport?, desktop: string?, node: string?, generation: integer?, fullscreen: boolean?}
-- A command bee runs with: the app command name and the words after it.
type Launch = {name: string, arguments: {string}}
type SavedWindow = {id: string, handle: string}
type Saved = {target: string, origin: string, owner: string?, supervisor: string?, desktop: string,
    scenes: {[string]: model.Scene}, orders: {[string]: {string}}, windows: {SavedWindow}, welcomed: boolean,
    appearance: appearance.Preferences?}
type TabHit = {id: string, x: integer, width: integer, action: string?}

local function saved_handover(value: unknown): Saved?
    if type(value) ~= "table" or type(value.target) ~= "string" or type(value.origin) ~= "string"
        or type(value.desktop) ~= "string" or type(value.scenes) ~= "table" or type(value.orders) ~= "table"
        or type(value.windows) ~= "table" then
        return nil
    end
    return value :: Saved
end

-- display shows target's desktops on this terminal until Ctrl+Q. saved is
-- the handover of an upgraded predecessor.
local function display(target: string, saved: Saved?, launch: Launch?): integer
    assert(process.set_options({upgradable = true}))
    local lifecycle = assert(process.events())
    local inputs = assert(tty.events())
    local node_events = assert(process.listen(client.EVENTS, {message = true}))
    assert(tty.start())
    tty.mouse(true)
    local surface = assert(tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true}))
    local screen_width, screen_height = tty.screen_size()
    local width, height = math.floor(screen_width), math.floor(screen_height)

    local preferences = appearance.defaults()
    -- themed is set once this display knows its node's appearance; until then
    -- it shows the loader, so no default theme flashes before the node's.
    local themed = false
    if saved and saved.appearance then
        local handed = appearance.decode(saved.appearance)
        if handed then preferences, themed = handed, true end
    end
    local catalog: {menu.Descriptor} = {}
    local catalog_ready = false
    local workspaces: {client.Workspace} = {}
    local desktops: {client.Desktop} = {}
    local running: {client.Instance} = {}
    local owner: string? = nil
    local desktop = ""
    if saved then owner, desktop = saved.owner, saved.desktop end
    local scenes: {[string]: model.Scene} = {}
    local orders: {[string]: {string}} = {}
    local views: {[string]: tty.Viewport} = {}
    local updates: {[string]: channel.Channel} = {}
    local contents: {[string]: render.Content} = {}
    local revisions: {[string]: integer} = {}
    local sizes: {[string]: string} = {}
    local status = "Connecting to " .. target .. "…"
    local start: menu.State? = nil
    local editor: title_editor.State? = nil
    local modal: dialog.State? = nil
    -- pending_launch is the command this display opens once it knows the
    -- node; full holds the app instances to show full-pane when they come.
    local pending_launch = launch
    local full: {[string]: boolean} = {}
    -- Windows this display opened take the keyboard once they arrive. While
    -- the person works in a full-pane window, a window another display opened
    -- joins without it.
    local focus_pending: {[string]: boolean} = {}
    -- Windows that ask for the person arrive beneath the window the person
    -- types in, and take the keyboard only when no window holds it.
    local attention_pending: {[string]: boolean} = {}
    -- app_dialogs holds the dialogs apps ask, by app instance; the display
    -- shows those of the apps on its desktop, one at a time.
    local app_dialogs: {[string]: client.Dialog} = {}
    local APP_DIALOG = "app:"
    local active_selection: selection.State? = nil
    local workspaces_open: workspace_menu.Menu? = nil
    local capture: layout.Capture? = nil
    local preview: model.Rect? = nil
    local tab_hits: {TabHit} = {}
    local stopped: string? = nil
    local results = channel.new(16)
    -- supervisor is the node's Hive supervisor; its exit means the node
    -- stopped, while the owner alone exiting means the node service restarts.
    local supervisor: string? = saved and saved.supervisor or nil
    -- revision is the last node event applied. Until a watch snapshot is
    -- applied, events wait in pending and replay after it.
    local revision = 0
    local synced = false
    local pending: {client.Event} = {}
    local pending_from: {string} = {}

    -- Scenes and window orders are kept per node and desktop, so returning to
    -- a node or desktop finds its windows where this display left them.
    local function place(): string return target .. "/" .. desktop end
    local function scene(): model.Scene
        local value = scenes[place()]
        if not value then
            value = model.new(width, height)
            scenes[place()] = value
        end
        if value.width ~= width or value.height ~= height then
            value = model.resize_screen(value, width, height)
            scenes[place()] = value
        end
        return value
    end
    local function set_scene(value: model.Scene) scenes[place()] = value end
    local function order(): {string}
        local value = orders[place()]
        if not value then
            value = {}
            orders[place()] = value
        end
        return value
    end

    local generation = 0
    -- welcomed is set once the first desktop is shown; only then does an
    -- empty desktop open the Start panel.
    local welcomed = saved ~= nil and saved.welcomed == true
    -- notice explains a change the display made on its own; it shows after the
    -- next connection until the next key or click.
    local notice: string? = nil
    local noticed = false

    local function run(job: () -> Result)
        local stamp = generation
        coroutine.spawn(function()
            local result = job()
            result.generation = stamp
            results:send(result)
        end)
    end

    -- attaching holds the apps this display is attaching, so it attaches each
    -- app once however many reasons it has to.
    local attaching: {[string]: boolean} = {}

    local function attach_job(id: string, shown: string): Result
        local attached, attach_error = client.call(target, "attach", {id = id})
        if not attached then return {kind = "failed", id = id, problem = attach_error} end
        if type(attached.ref) ~= "string" then return {kind = "failed", id = id, problem = "attach returned no mount"} end
        local view, view_error = tty.attach(attached.ref)
        if not view then return {kind = "failed", id = id, problem = tostring(view_error)} end
        local title = id
        if type(attached.title) == "string" then title = attached.title end
        return {kind = "attached", id = id, title = title, view = view, desktop = shown}
    end

    local function call_job(op: string, args: {[string]: unknown}): Result
        local _, err = client.call(target, op, args)
        if err then return {kind = "failed", problem = err} end
        return {kind = "done"}
    end

    -- watch_job watches target once its owner serves. A node without a
    -- serving owner reports "away", and the display waits for it again.
    local function watch_job(requested: string): Result
        if not client.serving(target) then return {kind = "away", desktop = requested} end
        local args: {[string]: unknown} = {}
        if requested ~= "" then args.desktop = requested end
        local value, watch_error = client.call(target, "watch", args)
        if not value then
            if not client.serving(target) then return {kind = "away", desktop = requested} end
            return {kind = "failed", problem = "Cannot reach " .. target .. ": " .. tostring(watch_error)}
        end
        local decoded = client.state(value)
        if not decoded then return {kind = "failed", problem = "malformed state from " .. target} end
        return {kind = "watched", state = decoded}
    end

    local function input_focus(): string return scene().focus end

    -- focus raises window id; the display that focuses an app sizes it.
    local function focus(id: string)
        set_scene(model.focus(scene(), id))
        sizes[id] = nil
    end

    -- app_counts counts the apps each desktop runs.
    -- counts_of is how many of instances run on each desktop.
    local function counts_of(instances: {client.Instance}): {[string]: integer}
        local counts: {[string]: integer} = {}
        for _, instance in ipairs(instances) do counts[instance.desktop] = (counts[instance.desktop] or 0) + 1 end
        return counts
    end

    local function app_counts(): {[string]: integer}
        return counts_of(running)
    end

    -- origin is the node this display started on; another node's desktops
    -- carry its name on the bar.
    local origin = saved and saved.origin or target

    local function desktop_label(): string
        local label = workspace_menu.describe(desktops, workspaces, desktop) or target
        if target ~= origin then label = label .. " @ " .. target end
        return label
    end

    -- detach closes this display's views; windows keep their placement in the
    -- desktop's scene for when the display shows it again.
    local function detach()
        for id, view in pairs(views) do
            view:close()
            views[id] = nil
        end
        updates, contents, sizes, revisions, attaching = {}, {}, {}, {}, {}
        active_selection = nil
        capture, preview = nil, nil
    end

    local function forget(id: string)
        local view = views[id]
        if view then view:close() end
        views[id], updates[id], contents[id], sizes[id], revisions[id], attaching[id] = nil, nil, nil, nil, nil, nil
        for value_desktop, value in pairs(scenes) do scenes[value_desktop] = model.remove(value, id) end
        for _, list in pairs(orders) do
            for index, item in ipairs(list) do
                if item == id then table.remove(list, index); break end
            end
        end
    end

    -- show attaches the apps desktop runs and drops windows of apps that
    -- stopped while this display showed another desktop.
    local function attach(id: string)
        if views[id] or attaching[id] then return end
        attaching[id] = true
        local shown = desktop
        run(function(): Result return attach_job(id, shown) end)
    end

    local function show(next_desktop: string)
        if next_desktop ~= desktop then detach() end
        desktop = next_desktop
        local live: {[string]: boolean} = {}
        for _, instance in ipairs(running) do
            if instance.desktop == desktop then
                live[instance.id] = true
                attach(instance.id)
            end
        end
        for _, win in ipairs(scene().windows) do
            if not live[win.id] then forget(win.id) end
        end
    end

    -- connect watches target again from a new connection: results of the
    -- earlier one are dropped and events wait for the new snapshot.
    -- leaving names a node to leave first, in the same job, so the leave
    -- always reaches it before this display could watch it again.
    local function connect(requested: string, leaving: string?)
        generation = generation + 1
        synced, pending, pending_from = false, {}, {}
        attaching = {}
        run(function(): Result
            if leaving then client.call(leaving, "leave", {}) end
            return watch_job(requested)
        end)
    end

    -- retarget shows the desktops of another node in the hive: the display
    -- leaves this node, unless it is gone, and watches that one, on the
    -- desktop requested when one is.
    local function retarget(node: string, gone: boolean?, requested: string?)
        if node == target then return end
        local left: string? = target
        if gone then left = nil end
        if owner then process.unmonitor(owner) end
        if supervisor then process.unmonitor(supervisor) end
        owner, supervisor = nil, nil
        detach()
        revision = 0
        running, catalog, catalog_ready, workspaces, desktops = {}, {}, false, {}, {}
        desktop = ""
        target = node
        status = "Connecting to " .. target .. "…"
        connect(requested or "", left)
    end

    -- switch shows next_desktop once the node has recorded that this display
    -- shows it, so the node never closes a desktop a display is switching to.
    local function switch(next_desktop: string)
        if next_desktop == desktop then return end
        local chosen = next_desktop
        run(function(): Result
            local _, err = client.call(target, "show", {desktop = chosen})
            if err then return {kind = "failed", problem = err} end
            return {kind = "shown", desktop = chosen}
        end)
    end

    local function refresh(id: string)
        local view = views[id]
        if not view then return end
        local revision = revisions[id]
        local snapshot = revision and view:snapshot(revision) or view:snapshot()
        if snapshot then
            contents[id] = {rows = snapshot.rows, cursor = snapshot.cursor}
            revisions[id] = snapshot.revision
        end
    end

    -- fit sizes each visible app to its window body: this display takes over
    -- an app's size whenever it shows or reshapes the window.
    local function fit()
        local current = scene()
        for _, win in ipairs(model.visible(current)) do
            local view = views[win.id]
            if view and win.mode ~= "collapsed" then
                local body = layout.interior(win, layout.rectangle(current, win, nil, nil))
                local size = tostring(body.width) .. "x" .. tostring(body.height)
                if sizes[win.id] ~= size then
                    sizes[win.id] = size
                    view:resize(math.max(1, body.width), math.max(1, body.height))
                end
            end
        end
    end

    local function adopt(id: string, title: string, view: tty.Viewport)
        local previous = views[id]
        if previous then previous:close() end
        views[id] = view
        updates[id] = assert(view:updates())
        sizes[id] = nil
        contents[id] = nil
        revisions[id] = nil
        local current = scene()
        local found = false
        for _, win in ipairs(current.windows) do
            if win.id == id then found = true end
        end
        if not found then
            local immersed = false
            for _, win in ipairs(current.windows) do
                if win.id == current.focus and win.mode == "fullscreen" then immersed = true end
            end
            local focused = focus_pending[id] == true or not immersed
            focus_pending[id] = nil
            if attention_pending[id] then
                attention_pending[id] = nil
                set_scene(model.attend(model.add(current, id, id, title, nil, nil, false), id))
            else
                set_scene(model.add(current, id, id, title, nil, nil, focused))
            end
            local list = order()
            list[#list + 1] = id
        end
        if full[id] then
            full[id] = nil
            set_scene(model.toggle_fullscreen(scene(), id))
        end
        refresh(id)
    end

    -- open_app asks the node to start app on this desktop; the node's opened
    -- event brings the window. A singleton app already running there comes
    -- back as the existing instance, which the display focuses.
    local function open_app(app: string)
        local shown = desktop
        run(function(): Result
            local value, err = client.call(target, "open", {app = app, desktop = shown})
            if err then return {kind = "failed", problem = err} end
            if type(value) ~= "table" or type(value.id) ~= "string" then return {kind = "failed", problem = "open returned no instance"} end
            if value.existing == true then return {kind = "existing", id = value.id} end
            return {kind = "launched", id = value.id, fullscreen = false}
        end)
    end

    -- launch_command opens the app the command names on this desktop, with
    -- its arguments, full-pane when the command says so.
    local function launch_command(given: Launch)
        local shown = desktop
        run(function(): Result
            local resolved, resolve_error = client.call(target, "command", {name = given.name, arguments = given.arguments})
            if not resolved then return {kind = "unlaunched", problem = resolve_error} end
            local opened, open_error = client.call(target, "open", {app = resolved.app, desktop = shown,
                args = {arguments = resolved.arguments}})
            if not opened then return {kind = "unlaunched", problem = open_error} end
            if type(opened.id) ~= "string" then return {kind = "unlaunched", problem = "open returned no instance"} end
            return {kind = "launched", id = opened.id, fullscreen = resolved.fullscreen == true}
        end)
    end

    local function close_app(id: string)
        if id == "" then return end
        run(function(): Result return call_job("close", {id = id}) end)
    end

    local function selection_body(state: selection.State): model.Rect?
        local binding = selection.binding(state)
        local current = scene()
        for _, win in ipairs(model.visible(current)) do
            if win.id == binding.view_id and win.mode ~= "collapsed" then
                local body = layout.interior(win, layout.rectangle(current, win, nil, nil))
                local check: selection.Binding = {view_id = win.id, attachment = win.id, mount_generation = 0,
                    width = body.width, height = body.height}
                if selection.valid(state, check) then return body end
            end
        end
        return nil
    end

    local function begin_selection(id: string)
        local current = scene()
        local chosen: model.Window? = nil
        for _, win in ipairs(model.visible(current)) do
            if win.id == id and win.mode ~= "collapsed" then chosen = win end
        end
        if not chosen then status = "Text selection unavailable: window is not visible"; return end
        local content = contents[id]
        if not content then status = "Text selection unavailable: view has no content"; return end
        local body = layout.interior(chosen, layout.rectangle(current, chosen, nil, nil))
        local rows: {string} = {}
        for y = 1, body.height do rows[y] = tty.text.cut(content.rows[y] or "", 0, body.width) end
        local captured, capture_error = selection.capture({view_id = id, attachment = id, mount_generation = 0,
            width = body.width, height = body.height}, rows)
        if not captured then status = "Text selection unavailable: " .. tostring(capture_error); return end
        active_selection = captured
        status = "Select text: drag to select; Ctrl+C copies; Esc cancels"
    end

    local function copy_selection()
        local state = active_selection
        if not state then return end
        local text, err = selection.text(state)
        if not text then status = "Nothing copied: " .. tostring(err or "select text first"); return end
        local copied, copy_error = surface:clipboard(text)
        active_selection = nil
        status = copied and "Copied" or ("Copy failed: " .. tostring(copy_error))
    end

    local function ask(spec: dialog.Spec)
        start, workspaces_open = nil, nil
        modal = dialog.open(spec)
    end

    -- app_dialog_id names an app dialog in the modal: the instance and the
    -- request it answers.
    local function app_dialog_id(item: client.Dialog): string
        return APP_DIALOG .. item.id .. ":" .. item.request_id
    end

    -- show_app_dialog opens the next dialog an app on this desktop asks, when
    -- no other dialog is open.
    local function show_app_dialog()
        if modal then return end
        for _, instance in ipairs(running) do
            local item = app_dialogs[instance.id]
            if item and instance.desktop == desktop then
                ask({id = app_dialog_id(item), kind = item.kind, title = item.title, message = item.message,
                    accept = item.accept, initial = item.initial})
                return
            end
        end
    end

    -- drop_app_dialog forgets an app's dialog and closes it if it is shown.
    local function drop_app_dialog(id: string)
        local item = app_dialogs[id]
        app_dialogs[id] = nil
        local current = modal
        if item and current and current.spec.id == app_dialog_id(item) then modal = nil end
        show_app_dialog()
    end

    -- answer_app sends the person's answer to the dialog spec_id names.
    local function answer_app(spec_id: string, action: string, value: string)
        local id, request_id = spec_id:sub(#APP_DIALOG + 1):match("^([^:]+):(.+)$")
        if not id or not request_id then return end
        app_dialogs[id] = nil
        run(function(): Result
            return call_job("answer", {id = id, request_id = request_id, action = action, value = value})
        end)
    end

    -- new_desktop creates a desktop working in the shown desktop's workspace
    -- and shows it on this display.
    local function new_desktop()
        local folder: string? = nil
        for _, item in ipairs(desktops) do
            if item.id == desktop then folder = item.workspace end
        end
        local args: {[string]: unknown} = {}
        if folder then args.workspace = folder end
        run(function(): Result
            local created, err = client.call(target, "desktop_create", args)
            if not created then return {kind = "failed", problem = err} end
            if type(created.desktop) ~= "string" then return {kind = "failed", problem = "desktop_create returned no desktop"} end
            return {kind = "switch", desktop = created.desktop}
        end)
    end

    -- use_workspace makes the shown desktop work in workspace.
    local function use_workspace(workspace: string)
        local shown = desktop
        run(function(): Result return call_job("desktop_workspace", {id = shown, workspace = workspace}) end)
    end

    -- invoke runs a menu or control action on target or the focused window.
    local function invoke(action: string, selected_target: string?)
        local id = selected_target or (start and start.target) or input_focus()
        start = nil
        local current = scene()
        local win: model.Window? = nil
        for _, item in ipairs(current.windows) do
            if item.id == id then win = item end
        end
        if action == "select_text" then begin_selection(id)
        elseif action == "rename" and win then editor = title_editor.open(win.id, model.display_title(win), win.accent or "")
        elseif action:sub(1, 7) == "accent:" and win then set_scene(model.personalize(current, win.id, win.user_title or "", action:sub(8)))
        elseif action == "quit" then stopped = ""
        elseif action:sub(1, 5) == "open:" then open_app(action:sub(6))
        elseif action == "close" then close_app(id)
        elseif action:sub(1, 5) == "move:" then
            local destination = action:sub(6)
            run(function(): Result return call_job("move", {id = id, desktop = destination}) end)
        elseif action == "workspaces" then
            local nodes = client.nodes()
            workspaces_open = workspace_menu.new(desktop, desktops, workspaces, app_counts(), nodes, target)
            if #nodes > 1 then
                for _, node in ipairs(nodes) do
                    run(function(): Result
                        local value = client.call(node, "workspaces", {})
                        if not value then return {kind = "done"} end
                        local home = value.home
                        for _, workspace in ipairs(client.workspaces(value.workspaces)) do
                            if workspace.id == home then return {kind = "labelled", id = node, title = workspace.label} end
                        end
                        return {kind = "done"}
                    end)
                end
            end
        elseif action == "new_desktop" then new_desktop()
        elseif action == "restore" and win then
            local restored = win.mode == "fullscreen" and model.toggle_fullscreen(current, win.id) or model.restore(current, win.id)
            set_scene(model.focus(restored, win.id))
        elseif action == "fullscreen" and win then set_scene(model.toggle_fullscreen(current, win.id))
        elseif action == "minimize" and win then set_scene(model.minimize(current, win.id))
        elseif (action == "collapse" or action == "snap_left" or action == "snap_right") and win then
            local next_scene = current
            if win.mode == "fullscreen" then next_scene = model.toggle_fullscreen(next_scene, win.id) end
            if win.mode == "collapsed" then next_scene = model.restore(next_scene, win.id) end
            if action == "collapse" then next_scene = model.collapse(next_scene, win.id)
            else next_scene = model.snap(next_scene, win.id, action == "snap_left" and "left" or "right") end
            set_scene(next_scene)
        elseif action == "restore_all" then
            local next_scene = current
            for _, item in ipairs(current.windows) do
                next_scene = model.restore(next_scene, item.id)
                if item.mode == "minimized" and item.restore_mode == "collapsed" then next_scene = model.restore(next_scene, item.id) end
            end
            local list = order()
            if #list > 0 then next_scene = model.focus(next_scene, list[#list]) end
            set_scene(next_scene)
        elseif action == "rejoin" then
            detach()
            status = "Reloading…"
            connect(desktop)
        end
    end

    -- destinations are the desktops a window here can move to.
    local function destinations(): {menu.Destination}
        local found: {menu.Destination} = {}
        for _, item in ipairs(desktops) do
            if item.id ~= desktop then found[#found + 1] = {id = item.id, title = item.title} end
        end
        return found
    end

    local function paint()
        if not themed then
            surface:present(chrome.loader(width, height, status))
            return
        end
        fit()
        local current = scene()
        local drawn = render.draw(current, order(), contents, capture, preview, status, desktop_label(), preferences,
            {start = start, catalog = catalog, destinations = destinations(), editor = editor,
                modal = modal, selection = active_selection, workspaces = workspaces_open})
        tab_hits = drawn.tabs
        surface:present(drawn.rows, {cursor = drawn.cursor})
    end

    local function descriptors(apps: {client.App}): {menu.Descriptor}
        local found: {menu.Descriptor} = {}
        for _, app in ipairs(apps) do found[#found + 1] = {definition_id = app.id, title = app.title, menus = app.menus} end
        return found
    end

    -- receive applies the next node event; an older one is already in the
    -- snapshot and a gap means events were lost, so the display watches again.
    local receive: (event: client.Event) -> ()

    local function apply(result: Result)
        if result.generation ~= generation then
            if result.view then result.view:close() end
            return
        end
        if result.id and result.kind ~= "labelled" then attaching[result.id] = nil end
        if result.kind == "watched" and result.state then
            local node_state = result.state
            if owner ~= node_state.owner then
                if owner then process.unmonitor(owner) end
                local monitored, monitor_error = process.monitor(node_state.owner)
                if not monitored then status = "Cannot follow " .. target .. ": " .. tostring(monitor_error); return end
                owner = node_state.owner
            end
            if supervisor ~= node_state.supervisor and node_state.supervisor ~= "" then
                if supervisor then process.unmonitor(supervisor) end
                local monitored, monitor_error = process.monitor(node_state.supervisor)
                if not monitored then status = "Cannot follow " .. target .. ": " .. tostring(monitor_error); return end
                supervisor = node_state.supervisor
            end
            revision = node_state.revision
            preferences = node_state.appearance
            themed = true
            workspaces = node_state.workspaces
            desktops = node_state.desktops
            running = node_state.running
            catalog = descriptors(node_state.apps)
            catalog_ready = true
            app_dialogs = {}
            for _, item in ipairs(node_state.dialogs) do app_dialogs[item.id] = item end
            status = notice or ""
            noticed = notice ~= nil
            notice = nil
            show(node_state.desktop or desktop)
            local any = false
            for _, instance in ipairs(running) do
                if instance.desktop == desktop then any = true end
            end
            local given = pending_launch
            if given then
                pending_launch = nil
                any = true
                launch_command(given)
            end
            if not any and start == nil and not welcomed then start = {selected = 1, offset = 0} end
            welcomed = true
            show_app_dialog()
            synced = true
            local queued, senders = pending, pending_from
            pending, pending_from = {}, {}
            for index, event in ipairs(queued) do
                if senders[index] == owner and event.revision > revision then receive(event) end
            end
        elseif result.kind == "attached" and result.id and result.title and result.view then
            local id = result.id
            local live = false
            for _, instance in ipairs(running) do
                if instance.id == id and instance.desktop == desktop then live = true end
            end
            if live and not views[id] then
                adopt(id, result.title, result.view)
            else
                result.view:close()
            end
        elseif result.kind == "switch" and result.desktop then
            switch(result.desktop)
        elseif result.kind == "browsed" and result.node and result.state then
            if workspaces_open then
                workspace_menu.update(workspaces_open, result.node, result.state.desktops, result.state.workspaces, counts_of(result.state.running))
            end
        elseif result.kind == "labelled" and result.id and result.title then
            if workspaces_open then workspace_menu.label(workspaces_open, result.id, result.title) end
        elseif result.kind == "shown" and result.desktop then
            show(result.desktop)
            show_app_dialog()
        elseif result.kind == "away" then
            status = "Waiting for " .. target .. "…"
            connect(result.desktop or "")
        elseif result.kind == "launched" and result.id then
            if views[result.id] then focus(result.id) else focus_pending[result.id] = true end
            if result.fullscreen then
                if views[result.id] then set_scene(model.toggle_fullscreen(scene(), result.id))
                else full[result.id] = true end
            end
        elseif result.kind == "unlaunched" then
            stopped = tostring(result.problem)
        elseif result.kind == "existing" and result.id then
            if views[result.id] then focus(result.id) else focus_pending[result.id] = true end
        elseif result.kind == "failed" then
            status = tostring(result.problem)
        end
    end

    local function node_event(event: client.Event)
        if event.kind == "opened" and event.instance then
            local instance = event.instance
            if event.attention then attention_pending[instance.id] = true end
            running[#running + 1] = instance
            if instance.desktop == desktop then attach(instance.id) end
        elseif event.kind == "attention" and event.id then
            if views[event.id] then set_scene(model.attend(scene(), event.id)) else attention_pending[event.id] = true end
        elseif event.kind == "moved" and event.instance then
            local instance = event.instance
            for index, item in ipairs(running) do
                if item.id == instance.id then running[index] = instance end
            end
            if instance.desktop == desktop then attach(instance.id) else forget(instance.id) end
        elseif event.kind == "closed" and event.id then
            local id = event.id
            local kept: {client.Instance} = {}
            for _, instance in ipairs(running) do
                if instance.id ~= id then kept[#kept + 1] = instance end
            end
            running = kept
            if active_selection and selection.binding(active_selection).view_id == id then active_selection = nil end
            forget(id)
            drop_app_dialog(id)
        elseif event.kind == "title" and event.id and event.title then
            local id, title = event.id, event.title
            for _, instance in ipairs(running) do
                if instance.id == id then instance.title = title end
            end
            set_scene(model.announce(scene(), id, title))
        elseif event.kind == "dialog" and event.dialog then
            app_dialogs[event.dialog.id] = event.dialog
            show_app_dialog()
        elseif event.kind == "dialog_closed" and event.id then
            drop_app_dialog(event.id)
        elseif event.kind == "catalog" and event.apps then
            catalog = descriptors(event.apps)
        elseif event.kind == "appearance" and event.appearance then
            preferences = event.appearance
        elseif event.kind == "workspaces" and event.workspaces and event.desktops then
            workspaces, desktops = event.workspaces, event.desktops
            local present: {[string]: boolean} = {}
            for _, item in ipairs(desktops) do present[target .. "/" .. item.id] = true end
            local prefix = target .. "/"
            for key in pairs(scenes) do
                if key:sub(1, #prefix) == prefix and not present[key] then scenes[key], orders[key] = nil, nil end
            end
            if workspaces_open then workspace_menu.update(workspaces_open, target, desktops, workspaces, app_counts()) end
        end
    end

    receive = function(event: client.Event)
        if event.revision <= revision then return end
        if event.revision > revision + 1 then
            status = "Reconnecting…"
            connect(desktop)
            return
        end
        revision = event.revision
        node_event(event)
    end

    local function answer(spec_id: string, value: string)
        if spec_id:sub(1, #APP_DIALOG) == APP_DIALOG then
            answer_app(spec_id, "accept", value)
        elseif spec_id == "workspace_add" then
            local path, shown = value, desktop
            run(function(): Result
                local added, err = client.call(target, "workspace_add", {path = path})
                if not added then return {kind = "failed", problem = err} end
                if type(added.workspace) ~= "string" then return {kind = "failed", problem = "workspace_add returned no workspace"} end
                return call_job("desktop_workspace", {id = shown, workspace = added.workspace})
            end)
        elseif spec_id:sub(1, 15) == "desktop_rename:" then
            local id = spec_id:sub(16)
            run(function(): Result return call_job("desktop_rename", {id = id, title = value}) end)
        elseif spec_id:sub(1, 14) == "desktop_close:" then
            local id = spec_id:sub(15)
            run(function(): Result return call_job("desktop_close", {id = id}) end)
        end
    end

    local function send_focused(event: tty.InputEvent)
        local view = views[input_focus()]
        if view then
            local sent, err = view:send(event)
            if not sent then status = tostring(err) end
        end
    end

    local function on_bar(event: tty.MouseEvent)
        local x, y = event.x, event.y
        if event.action ~= "press" or (event.button ~= "left" and event.button ~= "right") then return end
        if x <= 7 and event.button == "left" then
            if start then start = nil else start = {selected = 1, offset = 0} end
            return
        end
        for _, hit in ipairs(tab_hits) do
            if x >= hit.x and x < hit.x + hit.width then
                if hit.action == "workspaces" then invoke("workspaces")
                elseif event.button == "right" and hit.id ~= "" then
                    start = {selected = 1, offset = 0, kind = "window", target = hit.id, x = x, y = y + 1}
                elseif hit.action == "close" then close_app(hit.id)
                elseif hit.action == "minimize" then invoke("minimize", hit.id)
                elseif hit.action == "fullscreen" then invoke("fullscreen", hit.id)
                elseif hit.id ~= "" then focus(hit.id) end
                return
            end
        end
        if event.button == "right" then start = {selected = 1, offset = 0, kind = "desktop", x = x, y = y + 1} end
    end

    local function on_mouse(event: tty.MouseEvent)
        local x, y = event.x, event.y
        local current = scene()
        if capture then
            if event.action == "release" then
                local placed = layout.drag(current, capture, x, y) or preview
                if placed then set_scene(model.place(current, capture.id, placed)) end
                capture, preview = nil, nil
            else
                preview = layout.drag(current, capture, x, y)
            end
            return
        end
        if height >= 3 and y == 1 then on_bar(event); return end
        local visible = model.visible(current)
        for index = #visible, 1, -1 do
            local win = visible[index]
            local rect = layout.rectangle(current, win, nil, nil)
            if layout.contains(rect, x, y) then
                local body = layout.interior(win, rect)
                if event.action == "press" then
                    focus(win.id)
                    current = scene()
                end
                if event.action == "press" and event.button == "right"
                    and (event.shift ~= true or win.mode == "collapsed" or not layout.contains(body, x, y)) then
                    start = {selected = 1, offset = 0, kind = "window", target = win.id, x = x, y = y}
                    return
                end
                local control = layout.control_at(win, rect, x, y)
                if control and event.action == "press" and event.button == "left" then
                    invoke(control, win.id)
                    return
                end
                if event.action == "press" and event.button == "left" and (body.x ~= rect.x or win.mode == "collapsed") then
                    local edge = win.mode == "collapsed" and "move" or layout.edge(rect, x, y)
                    if edge ~= "" then capture = {id = win.id, x = x, y = y, bounds = rect, edge = edge} end
                end
                if not capture and win.mode ~= "collapsed" and layout.contains(body, x, y) then
                    local view = views[win.id]
                    if view then
                        view:send({type = "mouse", x = x - body.x + 1, y = y - body.y + 1, action = event.action,
                            button = event.button, ctrl = event.ctrl, alt = event.alt, shift = event.shift})
                    end
                end
                return
            end
        end
        if event.action == "press" then
            if event.button == "left" then set_scene(model.focus(current, ""))
            elseif event.button == "right" then start = {selected = 1, offset = 0, kind = "desktop", x = x, y = y} end
        end
    end

    -- browse_node feeds the open workspace menu node's catalog: this node's
    -- from what the display holds, another node's from its answer.
    local function browse_node(node: string?)
        if not node or not workspaces_open then return end
        if node == target then
            workspace_menu.update(workspaces_open, target, desktops, workspaces, app_counts())
            return
        end
        run(function(): Result
            local value, err = client.call(node, "list", {})
            if not value then return {kind = "failed", problem = "Cannot reach " .. node .. ": " .. tostring(err)} end
            local decoded = client.state(value)
            if not decoded then return {kind = "failed", problem = "malformed state from " .. node} end
            return {kind = "browsed", node = node, state = decoded}
        end)
    end

    local function on_workspaces(current_menu: workspace_menu.Menu, event: tty.TTYEvent)
        local response: workspace_menu.Response
        if event.type == "mouse" then
            if event.action ~= "press" then return end
            if not workspace_menu.contains(width, height, current_menu, event.x, event.y) then workspaces_open = nil; return end
            if event.button ~= "left" then return end
            local tab = workspace_menu.tab_at(current_menu, width, height, event.x, event.y)
            if tab then
                browse_node(workspace_menu.choose(current_menu, tab))
                return
            end
            local index = workspace_menu.row_at(current_menu, width, height, event.x, event.y)
            if not index then return end
            current_menu.selected = index
            response = workspace_menu.respond(current_menu, {type = "key", key = "enter", key_type = "enter", action = "press"})
        else
            response = workspace_menu.respond(current_menu, event)
        end
        if response.close then workspaces_open = nil end
        browse_node(response.browse)
        if response.node then retarget(response.node, nil, response.switch)
        elseif response.switch then switch(response.switch) end
        if response.create then new_desktop() end
        if response.forget then
            local id = response.forget.id
            run(function(): Result return call_job("workspace_remove", {id = id}) end)
        end
        if response.use then use_workspace(response.use) end
        if response.rename then
            ask({id = "desktop_rename:" .. response.rename.id, kind = "text", title = "Rename desktop",
                message = "", accept = "Rename", initial = response.rename.title})
        end
        if response.remove then
            ask({id = "desktop_close:" .. response.remove.id, kind = "confirm", title = "Close desktop",
                message = "Close " .. response.remove.title .. " and stop its apps?", accept = "Close", initial = ""})
        end
        if response.add then
            ask({id = "workspace_add", kind = "text", title = "Add workspace",
                message = "Absolute path of the folder", accept = "Add", initial = ""})
        end
    end

    local function on_key(event: tty.KeyEvent)
        local kind = event.key_type
        if event.action ~= "release" then
            if event.ctrl == true and event.key == "w" then close_app(input_focus()); return end
            if kind == "f9" and event.alt == true then invoke("minimize"); return end
            if kind == "f11" then invoke("fullscreen"); return end
            if kind == "f12" then invoke("rejoin"); return end
            if kind == "tab" and event.alt == true then
                local list = order()
                if #list > 0 then
                    local focused = input_focus()
                    local step = event.shift == true and -1 or 1
                    local next_id = step < 0 and list[#list] or list[1]
                    for index, id in ipairs(list) do
                        if id == focused then next_id = list[(index - 1 + step + #list) % #list + 1]; break end
                    end
                    focus(next_id)
                end
                return
            end
        end
        send_focused(event)
    end

    -- on_input routes one terminal event and reports whether the display quits.
    local function on_input(event: tty.TTYEvent): boolean
        if event.type == "close" then return true end
        if event.type == "resize" then
            width, height = math.floor(event.width), math.floor(event.height)
            active_selection = nil
            capture, preview = nil, nil
            if workspaces_open and not workspace_menu.available(width, height) then workspaces_open = nil end
            return false
        end
        if event.type == "key" and event.ctrl == true and event.key == "q" and event.action ~= "release" then return true end
        if noticed and (event.type == "key" or (event.type == "mouse" and event.action == "press")) then
            status, noticed = "", false
        end
        local current_modal = modal
        if current_modal then
            local response = dialog.respond(current_modal, event, width, height)
            modal = response.state
            if response.action == "accept" then
                modal = nil
                answer(current_modal.spec.id, response.value)
                show_app_dialog()
            elseif response.action == "cancel" then
                modal = nil
                if current_modal.spec.id:sub(1, #APP_DIALOG) == APP_DIALOG then answer_app(current_modal.spec.id, "cancel", "") end
                show_app_dialog()
            end
            return false
        end
        local current_editor = editor
        if current_editor then
            local response = title_editor.respond(current_editor, event, title_editor.panel(width, height))
            editor = response.state
            if response.action == "save" then
                set_scene(model.personalize(scene(), response.state.id, response.state.left .. response.state.right, response.state.accent))
                editor = nil
            elseif response.action == "cancel" then editor = nil end
            return false
        end
        local current_selection = active_selection
        if current_selection then
            local body = selection_body(current_selection)
            if not body then
                active_selection = nil
                status = "Text selection unavailable: view changed"
            elseif event.type == "key" and event.action ~= "release" and (event.key_type == "esc" or event.key_type == "escape") then
                active_selection = nil
                status = ""
            elseif event.type == "key" and event.action ~= "release" and event.ctrl == true and event.key:lower() == "c" then
                copy_selection()
            elseif event.type == "mouse" then
                local x, y = event.x - body.x + 1, event.y - body.y + 1
                if event.action == "press" and event.button == "left" then active_selection = selection.press(current_selection, x, y)
                elseif event.action == "motion" then active_selection = selection.motion(current_selection, x, y)
                elseif event.action == "release" and event.button == "left" then active_selection = selection.release(current_selection, x, y) end
            end
            return false
        end
        local current_menu = workspaces_open
        if current_menu then
            on_workspaces(current_menu, event)
            return false
        end
        if capture and event.type == "key" and (event.key_type == "esc" or event.key_type == "escape") and event.action ~= "release" then
            capture, preview = nil, nil
            return false
        end
        if event.type == "key" and event.key_type == "f1" and event.action ~= "release" then
            if start then start = nil else start = {selected = 1, offset = 0} end
            capture, preview = nil, nil
            return false
        end
        if event.type == "key" and event.key_type == "f3" and event.action ~= "release" then
            invoke("workspaces")
            return false
        end
        local current_start = start
        if current_start and not (event.type == "mouse" and height >= 3 and event.y == 1 and event.x <= 7 and event.action == "press") then
            local current = scene()
            local items = menu.entries(current_start, current, catalog, destinations())
            local panel = menu.panel(width, height, items, current_start)
            local response = menu.respond(current_start, panel, items, event)
            start = response.state
            if response.close then start = nil end
            if response.action ~= "" then invoke(response.action, current_start.target) end
            return false
        end
        if event.type == "key" then on_key(event)
        elseif event.type == "mouse" then on_mouse(event)
        elseif event.type == "paste" then send_focused(event) end
        return false
    end

    local function handover(): Saved
        local windows: {SavedWindow} = {}
        for id, view in pairs(views) do windows[#windows + 1] = {id = id, handle = view:handle()} end
        return {target = target, origin = origin, owner = owner, supervisor = supervisor, desktop = desktop, scenes = scenes,
            orders = orders, windows = windows, welcomed = welcomed, appearance = preferences}
    end

    if saved then
        scenes, orders = saved.scenes, saved.orders
        for _, item in ipairs(saved.windows) do
            local view, err = tty.attach(item.handle)
            if view then
                views[item.id] = view
                updates[item.id] = assert(view:updates())
                refresh(item.id)
            else
                status = "A window was lost across the upgrade: " .. tostring(err)
            end
        end
    end

    local upgrading = false
    connect(desktop)
    paint()

    -- handle applies one ready case and reports whether the display quits.
    local function handle(selected: unknown): boolean
        local chosen = selected :: {channel: unknown, ok: boolean, value: unknown}
        if chosen.channel == lifecycle then
            local event = chosen.value :: {kind: string, from: unknown}
            local from = tostring(event.from)
            if event.kind == process.event.CANCEL then return true end
            if event.kind == process.event.OUTDATED then upgrading = true; return true end
            if event.kind == process.event.EXIT or event.kind == process.event.MONITOR_DOWN then
                local kind = event.kind == process.event.EXIT and "exit" or "monitor_down"
                local action = watch.lost(kind, from, {owner = owner, supervisor = supervisor, target = target, origin = origin})
                if action == "home" then
                    -- Another node went away: show this display's own node again.
                    local lost = target
                    retarget(origin, true)
                    notice = "Node " .. lost:sub(1, 12) .. " stopped"
                elseif action == "stop" then
                    stopped = target .. " stopped"
                    return true
                elseif action == "reconnect" then
                    detach()
                    status = "Reconnecting to " .. target .. "…"
                    connect(desktop)
                end
            end
        elseif chosen.channel == results then
            apply(chosen.value :: Result)
        elseif chosen.channel == node_events then
            if not chosen.ok then return true end
            local message = chosen.value :: process.Message
            local event = client.event(message:payload():data())
            local from = tostring(message:from())
            if event then
                if not synced then
                    pending[#pending + 1] = event
                    pending_from[#pending_from + 1] = from
                elseif from == owner then
                    receive(event)
                end
            end
        elseif chosen.channel == inputs then
            if not chosen.ok then return true end
            if on_input(chosen.value :: tty.TTYEvent) then return true end
        else
            for id, updated in pairs(updates) do
                if chosen.channel == updated then
                    if chosen.ok then refresh(id) else updates[id] = nil end
                end
            end
        end
        return false
    end

    local function cases(): {unknown}
        local list = {inputs:case_receive(), lifecycle:case_receive(), results:case_receive(), node_events:case_receive()}
        for _, updated in pairs(updates) do list[#list + 1] = updated:case_receive() end
        return list
    end

    -- Each turn handles every ready case, then paints once.
    while not stopped do
        local quit = handle(channel.select(cases()))
        while not quit and not stopped do
            local ready = channel.select(cases(), true)
            if ready.default then break end
            quit = handle(ready)
        end
        if quit then break end
        paint()
    end
    if upgrading then
        -- The surface lease belongs to this code; input and viewports stay
        -- with the process for the new code to take over.
        local saved_state = handover()
        surface:close()
        process.upgrade("", saved_state)
        return 0
    end
    detach()
    surface:close()
    tty.mouse(false)
    tty.stop()
    if stopped and stopped ~= "" then
        io.print("bee: " .. stopped)
        return 1
    end
    return 0
end

-- main is bee: the display of this folder's node, opening the app a command
-- names when bee runs with one (bee claude). After an upgrade it
-- receives its predecessor's handover instead of command arguments.
local function main(...: unknown): integer
    local first: unknown = ...
    local handover = saved_handover(first)
    if handover then return display(handover.target, handover) end
    local given: Launch? = nil
    if select("#", ...) > 0 then
        if type(first) ~= "string" then
            io.print("bee: a command is a name")
            return 2
        end
        local tail: {string} = {}
        for index = 2, select("#", ...) do
            local word: unknown = select(index, ...)
            if type(word) ~= "string" then
                io.print("bee: command arguments are words")
                return 2
            end
            tail[#tail + 1] = word
        end
        given = {name = first, arguments = tail}
    end
    local node = system.node.id()
    if not node then io.print("bee: this node has no identity"); return 1 end
    return display(node, nil, given)
end

-- hive_node waits for a node of the hive whose owner serves desktops: the
-- first one serving now, else the first to serve after nodes join.
local function hive_node(): string?
    local subscription, subscribe_error = events.subscribe("cluster", "node.joined")
    if not subscription then
        io.print("bee client: cannot follow the hive: " .. tostring(subscribe_error))
        return nil
    end
    local joins = subscription:channel()
    local announced = false
    while true do
        local nodes = client.nodes()
        if #nodes == 0 then
            for _, member in ipairs(system.cluster.members() or {}) do
                if type(member.id) == "string" and member.id ~= system.node.id() and client.serving(member.id) then
                    nodes[#nodes + 1] = member.id
                end
            end
        end
        if #nodes > 0 then
            subscription:close()
            table.sort(nodes)
            return nodes[1]
        end
        if not announced then
            io.print("bee client: waiting for a node of the hive…")
            announced = true
        end
        local _, open = joins:receive()
        if not open then return nil end
    end
end

-- client is a display run by an in-memory client node: of the node it is
-- given (the one running in this folder), opening the app command given after
-- it, else of a node of the hive; the workspace menu moves it to any other.
local function client_display(...: unknown): integer
    local first: unknown = ...
    local handover = saved_handover(first)
    if handover then return display(handover.target, handover) end
    if type(first) == "string" and first ~= "" then
        -- The words after the node name are the app command bee was run with.
        local name: unknown = select(2, ...)
        if type(name) ~= "string" then return display(first, nil) end
        local tail: {string} = {}
        for index = 3, select("#", ...) do
            local word: unknown = select(index, ...)
            if type(word) ~= "string" then io.print("bee: command arguments are words"); return 2 end
            tail[#tail + 1] = word
        end
        return display(first, nil, {name = name, arguments = tail})
    end
    local node = hive_node()
    if not node then return 1 end
    return display(node, nil)
end

return {main = main, client = client_display}
