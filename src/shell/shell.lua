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
-- click on a window's frame, a tab or the desktop; a right click inside a
-- window goes to its app, and Shift+Right there opens the window's menu.
-- A left drag inside a window copies its text, Alt+Q labels the focused
-- window's tokens to copy and Alt+C opens copy mode over it.
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
local client = require("client")
local chrome = require("chrome")
local menu = require("menu")
local copy = require("copy")
local watch = require("watch")
local membership = require("membership")
local render = require("render")
local part_handover = require("part_handover")
local seam = require("seam")
local display_state = require("display_state")
local actions = require("actions")
local sync = require("sync")
local input = require("input")
type Launch = part_handover.Launch
type Saved = part_handover.Saved
type State = display_state.State
local saved_handover = part_handover.saved_handover

local function paint(state: State)
    if not state.themed then
        state.surface:present(chrome.loader(state.width, state.height, state.status))
        return
    end
    display_state.fit(state)
    local current = display_state.scene(state)
    local reviews: {[string]: client.Review} = {}
    for _, instance in ipairs(state.running) do if instance.review then reviews[instance.id] = instance.review end end
    local drawn = render.draw(current, display_state.order(state), state.contents, state.capture, state.preview, state.status,
        display_state.desktop_label(state), state.preferences,
        {reviews = reviews, alert = display_state.current_alert(state), alert_popup = state.alert_popup, start = state.start,
            catalog = state.catalog, destinations = menu.destinations(state.desktops, state.desktop), editor = state.editor,
            modal = state.modal, copy = copy.overlay(state.clip), workspaces = state.workspaces_open})
    state.tab_hits = drawn.tabs
    assert(state.surface:present(drawn.rows, {cursor = drawn.cursor}))
    state.presented_focus = current.focus
    state.presented_revisions = {}
    for id, revision in pairs(state.revisions) do state.presented_revisions[id] = revision end
end

-- display shows target's desktops on this terminal until Ctrl+Q. saved is
-- the handover of an upgraded predecessor.
local function display(target: string, saved: Saved?, launch: Launch?): integer
    assert(process.set_options({upgradable = true}))
    local lifecycle = assert(process.events())
    local inputs = assert(tty.events())
    local node_events = assert(process.listen(client.EVENTS, {message = true}))
    -- The Bees menu lists the hive's nodes that serve desktops. Membership
    -- events arrive on one subscription, in the order the cluster sends them,
    -- and the members are read only after it is open, so no join goes unseen.
    local membership_events = assert(events.subscribe("cluster"))
    local cluster = membership_events:channel()
    assert(tty.start())
    tty.mouse(true)
    local surface = assert(tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true}))
    local screen_width, screen_height = tty.screen_size()
    local state = display_state.new(target, saved, launch, surface, math.floor(screen_width), math.floor(screen_height))
    for _, member in ipairs(system.cluster.members() or {}) do
        if type(member.id) == "string" then actions.check(state, membership.member(state.hive, member.id)) end
    end
    local results, served = state.results, state.served

    local upgrading = false
    actions.connect(state, state.desktop)
    paint(state)

    local function cases()
        local list = {inputs:case_receive(), lifecycle:case_receive(), results:case_receive(), node_events:case_receive(),
            cluster:case_receive(), served:case_receive()}
        if state.alert_fade then list[#list + 1] = state.alert_fade:case_receive() end
        for _, updated in pairs(state.updates) do list[#list + 1] = updated:case_receive() end
        return list
    end

    -- handle applies one ready case and reports whether the display quits.
    local function handle(chosen: channel.SelectResult): boolean
        if chosen.channel == state.alert_fade then
            state.alert_fade = nil; state.alert_popup = false
        elseif chosen.channel == lifecycle then
            local event = chosen.value
            local from = tostring(event.from)
            if event.kind == process.event.CANCEL then return true end
            if event.kind == process.event.OUTDATED then upgrading = true; return true end
            if event.kind == process.event.EXIT or event.kind == process.event.MONITOR_DOWN then
                local kind = event.kind == process.event.EXIT and "exit" or "monitor_down"
                local action = watch.lost(kind, from, {owner = state.owner, supervisor = state.supervisor, target = state.target, origin = state.origin})
                if action == "home" then
                    -- Another node went away: show this display's own node again.
                    local lost = state.target
                    actions.retarget(state, state.origin, true)
                    state.notice = "Node " .. lost:sub(1, 12) .. " stopped"
                elseif action == "stop" then
                    state.stopped = state.target .. " stopped"
                    return true
                elseif action == "reconnect" then
                    if from == state.owner then state.owner = nil end
                    if from == state.supervisor then state.supervisor = nil end
                    display_state.detach(state)
                    state.status = "Reconnecting to " .. state.target .. "…"
                    actions.connect(state, state.desktop)
                end
            end
        elseif chosen.channel == results then
            sync.apply(state, chosen.value)
            seam.call("bee.shell.shell.applied", chosen.value.kind)
        elseif chosen.channel == cluster then
            if not chosen.ok then return true end
            local probe, change = membership.observe(state.hive, chosen.value)
            actions.check(state, probe)
            if change then actions.follow_hive(state, change) end
        elseif chosen.channel == served then
            local answer = chosen.value
            local change = membership.served(state.hive, answer.check, answer.serving)
            if change then actions.follow_hive(state, change) end
        elseif chosen.channel == node_events then
            if not chosen.ok then return true end
            local message = chosen.value
            local event = client.event(message:payload():data())
            local from = tostring(message:from())
            if event then
                if not state.synced then
                    state.pending[#state.pending + 1] = event
                    state.pending_from[#state.pending_from + 1] = from
                elseif from == state.owner then
                    sync.receive(state, event)
                end
            end
        elseif chosen.channel == inputs then
            if not chosen.ok then return true end
            if input.on_input(state, chosen.value) then return true end
        else
            for id, updated in pairs(state.updates) do
                if chosen.channel == updated then
                    if chosen.ok then display_state.refresh(state, id) else state.updates[id] = nil end
                end
            end
        end
        return false
    end

    -- Each turn handles every ready case, then paints once.
    while not state.stopped do
        local quit = handle(channel.select(cases()))
        while not quit and not state.stopped do
            local ready = channel.select(cases(), true)
            if ready.default then break end
            quit = handle(ready)
        end
        if quit then break end
        paint(state)
    end
    if upgrading then
        -- The surface lease belongs to this code; input and viewports stay
        -- with the process for the new code to take over.
        local saved_state = display_state.handover(state)
        membership_events:close()
        surface:close()
        process.upgrade("", saved_state)
        return 0
    end
    membership_events:close()
    display_state.detach(state)
    surface:close()
    tty.mouse(false)
    tty.stop()
    local stopped = state.stopped
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
-- first one serving, else the first to serve after nodes join.
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
