-- MIT. What a display asks of its node and does on the person's behalf: node
-- calls run in coroutines and report back on the display's results channel,
-- tagged with the connection they belong to, so the display answers input and
-- cancellation while it waits. Menu and window-control actions, app dialogs,
-- copying and the workspace menu's node browsing start here.
local process = require("process")
local client = require("client")
local model = require("model")
local dialog = require("dialog")
local title_editor = require("title_editor")
local copy = require("copy")
local workspace_menu = require("workspace_menu")
local membership = require("membership")
local part_handover = require("part_handover")
local display_state = require("display_state")
local M = {}
type Result = part_handover.Result
type Binding = part_handover.Binding
type Launch = part_handover.Launch
type State = display_state.State

function M.run(state: State, job: () -> Result)
    local stamp = state.generation
    local results = state.results
    coroutine.spawn(function()
        local result = job()
        result.generation = stamp
        results:send(result)
    end)
end
local run = M.run

-- check asks whether the node probe names serves desktops; the answer comes
-- on the display's served channel.
function M.check(state: State, probe: membership.Check?)
    if not probe then return end
    local served = state.served
    coroutine.spawn(function()
        served:send({check = probe, serving = client.serving(probe.node)})
    end)
end

-- label_node asks node for the folder it runs in, which names its tab.
local function label_node(state: State, node: string)
    run(state, function(): Result
        local value = client.call(node, "workspaces", {})
        if not value then return {kind = "done"} end
        local home = value.home
        for _, workspace in ipairs(client.workspaces(value.workspaces)) do
            if workspace.id == home then return {kind = "labelled", id = node, title = workspace.label} end
        end
        return {kind = "done"}
    end)
end

function M.follow(state: State, pid: string): Binding
    if state.owner == pid then return {ok = true} end
    if state.owner then process.unmonitor(state.owner) end
    state.owner = nil
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then return {ok = false, problem = tostring(monitor_error), vanished = monitor_error:kind() == errors.NOT_FOUND} end
    state.owner = pid
    return {ok = true}
end

-- follow_hive keeps an open Bees menu on the nodes that serve desktops.
function M.follow_hive(state: State, change: membership.Change)
    local open = state.workspaces_open
    if not open then return end
    if change.serving then
        -- A strip of one node has no tabs to label until a second joins.
        workspace_menu.join(open, change.node)
        for _, node in ipairs(open.nodes) do
            if not open.labels[node] then label_node(state, node) end
        end
    elseif workspace_menu.leave(open, change.node) then
        workspace_menu.update(open, state.target, state.desktops, state.workspaces, display_state.app_counts(state))
    end
end

local function attach(state: State, id: string)
    if state.views[id] or state.attaching[id] then return end
    state.attaching[id] = true
    local shown = state.desktop
    local attach_job = state.jobs.attach_job
    run(state, function(): Result return attach_job(id, shown) end)
end
M.attach = attach

-- show attaches the apps next_desktop runs and drops windows of apps that
-- stopped while the display showed another desktop.
function M.show(state: State, next_desktop: string)
    if next_desktop ~= state.desktop then display_state.detach(state) end
    state.desktop = next_desktop
    local live: {[string]: boolean} = {}
    for _, instance in ipairs(state.running) do
        if instance.desktop == state.desktop then
            live[instance.id] = true
            attach(state, instance.id)
        end
    end
    for _, win in ipairs(display_state.scene(state).windows) do
        if not live[win.id] then display_state.forget(state, win.id) end
    end
end

-- connect watches target again from a new connection: results of the
-- earlier one are dropped and events wait for the new snapshot.
-- leaving names a node to leave first, in the same job, so the leave
-- always reaches it before the display could watch it again.
function M.connect(state: State, requested: string, leaving: string?)
    state.generation = state.generation + 1
    state.synced, state.pending, state.pending_from = false, {}, {}
    state.attaching = {}
    local node, stamp = state.target, state.generation
    local watch_job = state.jobs.watch_job
    run(state, function(): Result
        if leaving then client.call(leaving, "leave", {}) end
        return watch_job(node, requested, stamp)
    end)
end
local connect = M.connect

-- retarget shows the desktops of another node in the hive: the display
-- leaves this node, unless it is gone, and watches that one, on the
-- desktop requested when one is.
function M.retarget(state: State, node: string, gone: boolean?, requested: string?)
    if node == state.target then return end
    local left: string? = state.target
    if gone then left = nil end
    if state.owner then process.unmonitor(state.owner) end
    if state.supervisor then process.unmonitor(state.supervisor) end
    state.owner, state.supervisor = nil, nil
    display_state.detach(state)
    state.revision = 0
    state.running, state.catalog, state.workspaces, state.desktops = {}, {}, {}, {}
    state.catalog_problem = nil
    state.desktop = ""
    state.target = node
    state.status = "Connecting to " .. state.target .. "…"
    connect(state, requested or "", left)
end

-- switch shows next_desktop once the node has recorded that the display
-- shows it, so the node never closes a desktop a display is switching to.
function M.switch(state: State, next_desktop: string)
    if next_desktop == state.desktop then return end
    local chosen = next_desktop
    run(state, function(): Result
        local _, err = client.call(state.target, "show", {desktop = chosen})
        if err then return {kind = "failed", problem = err} end
        return {kind = "shown", desktop = chosen}
    end)
end

-- open_app asks the node to start app on this desktop; the node's opened
-- event brings the window. A singleton app already running there comes
-- back as the existing instance, which the display focuses.
function M.open_app(state: State, app: string, arguments: {string}?)
    local shown = state.desktop
    run(state, function(): Result
        local value, err = client.call(state.target, "open", {app = app, desktop = shown, args = arguments and {arguments = arguments} or nil})
        if err then return {kind = "failed", problem = err} end
        if type(value) ~= "table" or type(value.id) ~= "string" then return {kind = "failed", problem = "open returned no instance"} end
        if value.existing == true then return {kind = "existing", id = value.id} end
        return {kind = "launched", id = value.id, fullscreen = false}
    end)
end
local open_app = M.open_app

-- launch_command opens the app the command names on this desktop, with
-- its arguments, full-pane when the command says so.
function M.launch_command(state: State, given: Launch)
    local shown = state.desktop
    run(state, function(): Result
        local resolved, resolve_error = client.call(state.target, "command", {name = given.name, arguments = given.arguments})
        if not resolved then return {kind = "unlaunched", problem = resolve_error} end
        local opened, open_error = client.call(state.target, "open", {app = resolved.app, desktop = shown,
            args = {arguments = resolved.arguments}})
        if not opened then return {kind = "unlaunched", problem = open_error} end
        if type(opened.id) ~= "string" then return {kind = "unlaunched", problem = "open returned no instance"} end
        return {kind = "launched", id = opened.id, fullscreen = resolved.fullscreen == true}
    end)
end

-- call runs op on the display's node with args.
function M.call(state: State, op: string, args: {[string]: unknown})
    local call_job = state.jobs.call_job
    run(state, function(): Result return call_job(op, args) end)
end
local call = M.call

function M.close_app(state: State, id: string)
    if id == "" then return end
    call(state, "close", {id = id})
end
local close_app = M.close_app

-- copied applies a copy outcome: events for the window's app, text for
-- the clipboard and the status that tells the person what happened.
function M.copied(state: State, id: string?, outcome: copy.Outcome)
    local view = id and state.views[id]
    if view then for _, item in ipairs(outcome.forward) do view:send(item) end end
    local value = outcome.copy
    if value then
        local done, err = state.surface:clipboard(value)
        state.status, state.noticed = copy.report(value, done == true, err and tostring(err)), true
    elseif outcome.status then state.status = outcome.status end
end

function M.begin_copy(state: State, mode: string, id: string)
    local body, content = copy.body(display_state.scene(state), id), state.contents[id]
    if not body or not content then state.status = "Text selection unavailable: the window shows no text"; return end
    M.copied(state, id, copy.begin(state.clip, mode, id, body, content.rows))
end

function M.ask(state: State, spec: dialog.Spec)
    state.start, state.workspaces_open = nil, nil
    state.modal = dialog.open(spec)
end

-- show_app_dialog opens the next dialog an app on this desktop asks, when
-- no other dialog is open.
function M.show_app_dialog(state: State)
    if state.modal then return end
    for _, instance in ipairs(state.running) do
        local item = state.app_dialogs[instance.id]
        if item and instance.desktop == state.desktop then
            M.ask(state, {id = display_state.app_dialog_id(item), kind = item.kind, title = item.title, message = item.message,
                accept = item.accept, initial = item.initial})
            return
        end
    end
end

-- drop_app_dialog forgets an app's dialog and closes it if it is shown.
function M.drop_app_dialog(state: State, id: string)
    local item = state.app_dialogs[id]
    state.app_dialogs[id] = nil
    local current = state.modal
    if item and current and current.spec.id == display_state.app_dialog_id(item) then state.modal = nil end
    M.show_app_dialog(state)
end

function M.retire(state: State, id: string)
    local kept: {client.Instance} = {}
    for _, instance in ipairs(state.running) do
        if instance.id ~= id then kept[#kept + 1] = instance end
    end
    state.running = kept
    copy.forget(state.clip, id)
    display_state.forget(state, id)
    M.drop_app_dialog(state, id)
end

-- answer_app sends the person's answer to the dialog spec_id names.
function M.answer_app(state: State, spec_id: string, action: string, value: string, gesture: string?)
    local id, request_id = spec_id:sub(#display_state.APP_DIALOG + 1):match("^([^:]+):(.+)$")
    if not id or not request_id then return end
    state.app_dialogs[id] = nil
    call(state, "answer", {id = id, request_id = request_id, action = action, value = value, gesture = gesture})
end

-- new_desktop creates a desktop working in the shown desktop's workspace
-- and shows it on the display.
function M.new_desktop(state: State)
    local folder: string? = nil
    for _, item in ipairs(state.desktops) do
        if item.id == state.desktop then folder = item.workspace end
    end
    local args: {[string]: unknown} = {}
    if folder then args.workspace = folder end
    run(state, function(): Result
        local created, err = client.call(state.target, "desktop_create", args)
        if not created then return {kind = "failed", problem = err} end
        if type(created.desktop) ~= "string" then return {kind = "failed", problem = "desktop_create returned no desktop"} end
        return {kind = "switch", desktop = created.desktop}
    end)
end

-- use_workspace makes the shown desktop work in workspace.
function M.use_workspace(state: State, workspace: string)
    call(state, "desktop_workspace", {id = state.desktop, workspace = workspace})
end

-- browse_node feeds the open workspace menu node's catalog: this node's
-- from what the display holds, another node's from its answer.
function M.browse_node(state: State, node: string?)
    local open = state.workspaces_open
    if not node or not open then return end
    if node == state.target then
        workspace_menu.update(open, state.target, state.desktops, state.workspaces, display_state.app_counts(state))
        return
    end
    run(state, function(): Result
        local value, err = client.call(node, "list", {})
        if not value then return {kind = "failed", problem = "Cannot reach " .. node .. ": " .. tostring(err)} end
        local decoded = client.state(value)
        if not decoded then return {kind = "failed", problem = "malformed state from " .. node} end
        return {kind = "browsed", node = node, state = decoded}
    end)
end

-- invoke runs a menu or control action on target or the focused window.
function M.invoke(state: State, action: string, selected_target: string?)
    local start = state.start
    local id = selected_target or (start and start.target) or display_state.input_focus(state)
    state.start = nil
    local current = display_state.scene(state)
    local win: model.Window? = nil
    for _, item in ipairs(current.windows) do
        if item.id == id then win = item end
    end
    if action == "attention" then
        local alert = display_state.current_alert(state)
        if alert then
            state.alert_popup = false
            local app = alert.app
            for _, instance in ipairs(state.running) do
                if instance.id == alert.id then app = instance.app; break end
            end
            if app then open_app(state, app, alert.installed and {} or {"--approval", alert.approval_id}) end
            if state.views[alert.id] then display_state.focus(state, alert.id) end
        end
    elseif action == "select_text" then M.begin_copy(state, "cursor", id)
    elseif action == "rename" and win then state.editor = title_editor.open(win.id, model.display_title(win), win.accent or "")
    elseif action:sub(1, 7) == "accent:" and win then display_state.set_scene(state, model.personalize(current, win.id, win.user_title or "", action:sub(8)))
    elseif action == "quit" then state.stopped = ""
    elseif action:sub(1, 5) == "open:" then open_app(state, action:sub(6))
    elseif action == "close" then close_app(state, id)
    elseif action:sub(1, 5) == "move:" then call(state, "move", {id = id, desktop = action:sub(6)})
    elseif action == "workspaces" then
        local nodes = membership.nodes(state.hive)
        state.workspaces_open = workspace_menu.new(state.desktop, state.desktops, state.workspaces, display_state.app_counts(state), nodes, state.target)
        if #nodes > 1 then
            for _, node in ipairs(nodes) do label_node(state, node) end
        end
    elseif action == "new_desktop" then M.new_desktop(state)
    elseif action == "restore" and win then
        local restored = win.mode == "fullscreen" and model.toggle_fullscreen(current, win.id) or model.restore(current, win.id)
        display_state.set_scene(state, model.focus(restored, win.id))
    elseif action == "fullscreen" and win then display_state.set_scene(state, model.toggle_fullscreen(current, win.id))
    elseif action == "minimize" and win then display_state.set_scene(state, model.minimize(current, win.id))
    elseif (action == "collapse" or action == "snap_left" or action == "snap_right") and win then
        local next_scene = current
        if win.mode == "fullscreen" then next_scene = model.toggle_fullscreen(next_scene, win.id) end
        if win.mode == "collapsed" then next_scene = model.restore(next_scene, win.id) end
        if action == "collapse" then next_scene = model.collapse(next_scene, win.id)
        else next_scene = model.snap(next_scene, win.id, action == "snap_left" and "left" or "right") end
        display_state.set_scene(state, next_scene)
    elseif action == "restore_all" then
        local next_scene = current
        for _, item in ipairs(current.windows) do
            next_scene = model.restore(next_scene, item.id)
            if item.mode == "minimized" and item.restore_mode == "collapsed" then next_scene = model.restore(next_scene, item.id) end
        end
        local list = display_state.order(state)
        if #list > 0 then next_scene = model.focus(next_scene, list[#list]) end
        display_state.set_scene(state, next_scene)
    elseif action == "rejoin" then
        display_state.detach(state)
        state.status = "Reloading…"
        connect(state, state.desktop)
    end
end

return M
