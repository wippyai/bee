-- MIT. How a display follows its node: it applies the results of the jobs it
-- ran and the node's events in revision order. A result of an earlier
-- connection is dropped; an event older than the applied snapshot is already
-- in it, and a gap means events were lost, so the display watches again.
local time = require("time")
local process = require("process")
local client = require("client")
local model = require("model")
local workspace_menu = require("workspace_menu")
local part_handover = require("part_handover")
local seam = require("seam")
local display_state = require("display_state")
local actions = require("actions")
local M = {}
type Result = part_handover.Result
type State = display_state.State

local function node_event(state: State, event: client.Event)
    if seam.call("bee.shell.shell.node_event", event) then return end
    if event.kind == "opened" and event.instance then
        local instance = event.instance
        if event.attention then state.attention_pending[instance.id] = true end
        state.running[#state.running + 1] = instance
        if instance.desktop == state.desktop then actions.attach(state, instance.id) end
    elseif event.kind == "attention" and event.id then
        local alerts = state.alerts
        if event.alert then
            for id, previous in pairs(alerts) do
                if event.alert.desktop and previous.desktop == event.alert.desktop and previous.app == event.alert.app
                    and id ~= event.id then alerts[id] = nil end
            end
            local previous = alerts[event.id]
            if not previous or previous.approval_id ~= event.alert.approval_id or event.alert.count > previous.count or event.alert.failed ~= previous.failed or event.alert.installed ~= previous.installed then
                state.alert_popup = true; state.alert_fade = time.after("3s")
            end
            alerts[event.id] = event.alert
        end
        if event.changed or (event.alert and event.alert.count == 0 and not event.alert.failed and not event.alert.installed) then return end
        if state.views[event.id] then display_state.set_scene(state, model.attend(display_state.scene(state), event.id)) else state.attention_pending[event.id] = true end
    elseif event.kind == "moved" and event.instance then
        local instance = event.instance
        for index, item in ipairs(state.running) do
            if item.id == instance.id then state.running[index] = instance end
        end
        if instance.desktop == state.desktop then actions.attach(state, instance.id) else display_state.forget(state, instance.id) end
    elseif event.kind == "closed" and event.id then
        actions.retire(state, event.id)
        if event.problem then state.status = event.problem end
    elseif event.kind == "review" and event.id then
        for _, instance in ipairs(state.running) do if instance.id == event.id then instance.review = event.review end end
    elseif event.kind == "title" and event.id and event.title then
        local id, title = event.id, event.title
        for _, instance in ipairs(state.running) do
            if instance.id == id then instance.title = title end
        end
        display_state.set_scene(state, model.announce(display_state.scene(state), id, title))
    elseif event.kind == "dialog" and event.dialog then
        state.app_dialogs[event.dialog.id] = event.dialog
        actions.show_app_dialog(state)
    elseif event.kind == "dialog_closed" and event.id then
        actions.drop_app_dialog(state, event.id)
    elseif event.kind == "catalog" and event.apps then
        state.catalog = display_state.descriptors(event.apps)
        if event.problem then
            state.catalog_problem = event.problem
            state.status = event.problem
        elseif state.catalog_problem then
            if state.status == state.catalog_problem then state.status = "" end
            state.catalog_problem = nil
        end
    elseif event.kind == "appearance" and event.appearance then
        state.preferences = event.appearance
    elseif event.kind == "workspaces" and event.workspaces and event.desktops then
        state.workspaces, state.desktops = event.workspaces, event.desktops
        local present: {[string]: boolean} = {}
        for _, item in ipairs(state.desktops) do present[state.target .. "/" .. item.id] = true end
        local prefix = state.target .. "/"
        for key in pairs(state.scenes) do
            if key:sub(1, #prefix) == prefix and not present[key] then state.scenes[key], state.orders[key] = nil, nil end
        end
        local open = state.workspaces_open
        if open then workspace_menu.update(open, state.target, state.desktops, state.workspaces, display_state.app_counts(state)) end
    end
end

-- receive applies the next node event.
function M.receive(state: State, event: client.Event)
    if event.revision <= state.revision then return end
    if event.revision > state.revision + 1 then
        state.status = "Reconnecting…"
        actions.connect(state, state.desktop)
        return
    end
    state.revision = event.revision
    node_event(state, event)
end

-- watched applies a node snapshot: the display follows the node's owner and
-- supervisor, takes the node's view of its apps and desktops, shows its
-- desktop and replays the events that waited for the snapshot.
local function watched(state: State, result: Result, node_state: client.State)
    if result.kind == "retired" then
        if node_state.owner ~= state.owner or node_state.revision < state.revision then return end
        node_state.desktop = state.desktop
        if result.id then actions.retire(state, result.id) end
    end
    local binding = actions.follow(state, node_state.owner)
    if not binding.ok then
        state.status = "Cannot follow " .. state.target .. ": " .. tostring(binding.problem)
        return
    end
    if state.supervisor ~= node_state.supervisor and node_state.supervisor ~= "" then
        if state.supervisor then process.unmonitor(state.supervisor) end
        local monitored, monitor_error = process.monitor(node_state.supervisor)
        if not monitored then state.status = "Cannot follow " .. state.target .. ": " .. tostring(monitor_error); return end
        state.supervisor = node_state.supervisor
    end
    state.revision = node_state.revision
    state.preferences = node_state.appearance
    state.themed = true
    state.workspaces = node_state.workspaces
    state.desktops = node_state.desktops
    state.running = node_state.running
    state.catalog = display_state.descriptors(node_state.apps)
    state.catalog_problem = node_state.problem
    state.alerts = {}
    for _, alert in ipairs(node_state.alerts or {}) do state.alerts[alert.id] = alert end
    state.app_dialogs = {}
    for _, item in ipairs(node_state.dialogs) do state.app_dialogs[item.id] = item end
    state.status = state.notice or state.catalog_problem or ""
    state.noticed = state.notice ~= nil
    state.notice = nil
    actions.show(state, node_state.desktop or state.desktop)
    local any = false
    for _, instance in ipairs(state.running) do
        if instance.desktop == state.desktop then any = true end
    end
    local given = state.pending_launch
    if given then
        state.pending_launch = nil
        any = true
        actions.launch_command(state, given)
    end
    if not any and state.start == nil and not state.welcomed then state.start = {selected = 1, offset = 0} end
    state.welcomed = true
    actions.show_app_dialog(state)
    state.synced = true
    local queued, senders = state.pending, state.pending_from
    state.pending, state.pending_from = {}, {}
    for index, event in ipairs(queued) do
        if senders[index] == state.owner and event.revision > state.revision then M.receive(state, event) end
    end
end

-- apply applies one job result.
function M.apply(state: State, result: Result)
    if result.generation ~= state.generation then
        if result.view then result.view:close() end
        if result.bound then result.bound:send({ok = false}) end
        return
    end
    if result.id and result.kind ~= "labelled" then state.attaching[result.id] = nil end
    if result.kind == "following" and result.following and result.bound then
        local binding = actions.follow(state, result.following)
        if binding.vanished then binding.problem = nil
        elseif binding.problem then binding.problem = "Cannot follow " .. state.target .. ": " .. binding.problem end
        result.bound:send(binding)
    elseif (result.kind == "watched" or result.kind == "retired") and result.state then
        watched(state, result, result.state)
    elseif result.kind == "attached" and result.id and result.title and result.view then
        local id = result.id
        local live = false
        for _, instance in ipairs(state.running) do
            if instance.id == id and instance.desktop == state.desktop then live = true end
        end
        if live and not state.views[id] then
            display_state.adopt(state, id, result.title, result.view)
        else
            result.view:close()
        end
    elseif result.kind == "switch" and result.desktop then
        actions.switch(state, result.desktop)
    elseif result.kind == "browsed" and result.node and result.state then
        local open = state.workspaces_open
        if open then
            workspace_menu.update(open, result.node, result.state.desktops, result.state.workspaces, display_state.counts_of(result.state.running))
        end
    elseif result.kind == "labelled" and result.id and result.title then
        local open = state.workspaces_open
        if open then workspace_menu.label(open, result.id, result.title) end
    elseif result.kind == "shown" and result.desktop then
        actions.show(state, result.desktop)
        actions.show_app_dialog(state)
    elseif result.kind == "away" then
        state.status = "Waiting for " .. state.target .. "…"
        actions.connect(state, result.desktop or "")
    elseif result.kind == "launched" and result.id then
        if state.views[result.id] then display_state.focus(state, result.id) else state.focus_pending[result.id] = true end
        if result.fullscreen then
            if state.views[result.id] then display_state.set_scene(state, model.toggle_fullscreen(display_state.scene(state), result.id))
            else state.full[result.id] = true end
        end
    elseif result.kind == "unlaunched" then
        state.stopped = tostring(result.problem)
    elseif result.kind == "existing" and result.id then
        if state.views[result.id] then display_state.focus(state, result.id) else state.focus_pending[result.id] = true end
    elseif result.kind == "failed" then
        if result.id then
            local live = false
            for _, instance in ipairs(state.running) do if instance.id == result.id then live = true end end
            if not live then return end
        end
        state.status = tostring(result.problem)
    end
end

return M
