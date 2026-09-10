-- MIT. The Hive Manager application: named Bees as membership and their
-- owners report them, each node's desktops as its owner lists them, and
-- explicit control or observe requests confirmed by the viewer. It reads
-- through one typed directory; the live directory asks this node's
-- supervisor and grants nothing, the fixture directory is a host-admitted
-- table named on every frame. Opening the manager enables no Hive.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local time = require("time")
local uuid = require("uuid")
local registry = require("registry")
local system = require("system")
local appearance = require("appearance")
local model = require("model")
local view = require("view")
local directory = require("directory")
local hive = require("hive")
local types = require("types")
local SOURCE = "bee.hive_manager:source"
local FIXTURE = "bee.hive_manager:fixture"
local NAMES = "bee.hive_manager:names"
local POLL = "5s"
local CALL_TIMEOUT = "2s"
type Object = {[string]: unknown}
local function entry_data(id: string): unknown
    local entry = registry.get(id)
    if not entry or type(entry.data) ~= "table" then return nil end
    return entry.data
end
local function own_node(): string
    local node = types.pid_parts(tostring(process.pid()))
    if not node or node == "" then return "local" end
    return node
end
-- The host selects the source. Anything but an explicit, decodable fixture
-- is the live directory; a fixture is never the silent default.
local function open_directory(handle: hive.Client): (directory.Directory, string)
    local source = entry_data(SOURCE)
    local kind = type(source) == "table" and (source :: Object).kind or nil
    if kind == directory.FIXTURE then
        local fixture, err = directory.decode_fixture(entry_data(FIXTURE))
        if not fixture then error("Invalid Hive Manager fixture: " .. tostring(err)) end
        return directory.fixture(fixture), fixture.label
    end
    return directory.live({
        local_node = own_node(),
        lookup = hive.supervisor,
        membership = function(): (unknown, unknown) return system.cluster.members() end,
        call = function(owner: types.OwnerRef, target: types.Target, input: {[string]: unknown}, options: {timeout: string?}): types.Reply
            return handle:call(owner, target, input, {timeout = options.timeout})
        end,
        timeout = CALL_TIMEOUT,
    }), ""
end
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local answers = assert(process.listen("bee.application.query.result", {message = true}))
    local handle, open_error = hive.open()
    if not handle then error("Hive client: " .. tostring(open_error)) end
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local source, source_label = open_directory(handle)
    local state: model.State = model.new(source.source, source_label, model.names(entry_data(NAMES)))
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid Hive Manager checkpoint") end
    local offset = 0
    local hits: {view.Hit} = {}
    local status = ""
    local announced = false
    local last_checkpoint = ""
    local running, dirty = true, true
    local dialog: {request_id: string, mode: directory.Mode}? = nil
    local ticker = assert(time.ticker(POLL))
    local ticks = ticker:channel()
    -- The Hive client has one reply listener: serialize calls in one worker,
    -- while the app actor continues drawing and handling input/cancellation.
    local updates = channel.new(1)
    local busy = false
    local function changed()
        dirty = true
        if running then updates:send(true) end
    end
    local function perform(operation: () -> ())
        if busy then status = "Query in progress"; dirty = true; return end
        busy = true
        coroutine.spawn(function()
            local ok, failure = pcall(operation)
            busy = false
            if not running then return end
            if not ok then status = "Query failed: " .. tostring(failure) end
            changed()
        end)
    end
    local supervisor_running = false
    local function refresh_local()
        local supervisor = source:supervisor()
        supervisor_running = supervisor.running
        model.set_supervisor(state, supervisor.running, supervisor.detail)
        local members, problem = source:members()
        model.apply_members(state, members, problem)
        dirty = true
    end
    local function refresh()
        for _, node in ipairs(state.nodes) do
            if not running then return end
            if node.member then
                if supervisor_running then model.apply_presence(state, node.node_id, source:presence(node.node_id))
                else model.apply_presence(state, node.node_id, types.reply_error("", types.fault("UNAVAILABLE", "no supervisor to ask"))) end
                changed()
            end
        end
        if not running then return end
        local selected = model.selected(state)
        if selected and selected.status == "reachable" then
            model.apply_stats(state, selected.node_id, source:stats(selected.node_id))
            if state.catalogs[selected.node_id] then model.apply_catalog(state, selected.node_id, source:desktops(selected.node_id)) end
        end
        dirty = true
    end
    local function request_refresh()
        if busy then status = "Query in progress"; dirty = true; return end
        -- These are local runtime reads, not peer probes. Show known Hive
        -- state immediately; only per-owner queries run in the worker.
        refresh_local()
        perform(refresh)
    end
    local function open_selected()
        local selected = model.selected(state)
        if not selected then status = "Select a node first"; dirty = true; return end
        model.apply_catalog(state, selected.node_id, source:desktops(selected.node_id))
        local current = model.selected(state)
        if current and current.node_id == selected.node_id then
            model.set_pane(state, "desktops")
            model.move(state, 1)
        end
        dirty = true
    end
    local function act(mode: directory.Mode)
        local intent: directory.Attach? = model.pending_intent(state)
        local refused: string? = nil
        if not intent then intent, refused = model.attach_intent(state, mode, uuid.v4()) end
        if not intent then status = refused or ""; dirty = true; return end
        status = ""
        dirty = true
        model.apply_outcome(state, intent, source:attach(intent))
        local selected = model.selected(state)
        if selected then model.apply_catalog(state, selected.node_id, source:desktops(selected.node_id)) end
        dirty = true
    end
    -- Control and observation are explicit choices confirmed through the
    -- shell; a selection or a key alone requests nothing of an owner.
    local function ask(mode: directory.Mode)
        if dialog then return end
        if state.pending then perform(function() act(mode) end); return end
        local desktop = model.selected_desktop(state)
        local node = model.selected(state)
        if not desktop or not node then status = "Select a desktop first"; dirty = true; return end
        if mode == "control" and not model.can_control(state) then status = "Desktop is controlled by " .. desktop.controller .. "; choose observe"; dirty = true; return end
        local title = mode == "control" and "Take control of this desktop?" or "Observe this desktop?"
        local message = model.text((desktop.label ~= "" and desktop.label or desktop.desktop_id) .. " on " .. node.label .. ", workspace " .. desktop.workspace_id, 512)
        local request_id, err = client.query(launch, {kind = "confirm", title = title, message = message, accept = mode == "control" and "Control" or "Observe"})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, mode = mode}
        dirty = true
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    request_refresh()
    while running do
        if dirty then
            local frame = view.draw(width, height, preferences, state, offset, status)
            hits = frame.hits
            offset = frame.offset
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            local checkpoint = model.checkpoint(state)
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive(), answers:case_receive(), ticks:case_receive(), updates:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == updates then
            dirty = true
        elseif event.channel == ticks then
            if not busy and not state.pending and not dialog then request_refresh() end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = appearance.decode(payload)
                if next_preferences and type(payload) == "table" and payload.version == 1 then preferences = next_preferences; dirty = true end
            end
        elseif event.channel == answers then
            local message = event.value
            local result = client.query_result(launch, tostring(message:from()), message:payload():data())
            if result and dialog and result.request_id == dialog.request_id then
                local asked = dialog
                dialog = nil
                if result.action == "accept" then perform(function() act(asked.mode) end) else status = "Cancelled"; dirty = true end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                local letter = tostring(data.key or "")
                status = ""
                if key == "up" or letter == "k" then model.move(state, -1); dirty = true
                elseif key == "down" or letter == "j" then model.move(state, 1); dirty = true
                elseif key == "pgup" then model.move(state, -8); dirty = true
                elseif key == "pgdown" then model.move(state, 8); dirty = true
                elseif key == "tab" then model.toggle_pane(state); dirty = true
                elseif key == "enter" then
                    if state.pane == "nodes" then perform(open_selected) else ask("observe") end
                elseif letter == "c" then ask("control")
                elseif letter == "o" then ask("observe")
                elseif letter == "r" then request_refresh()
                elseif letter == "t" then model.toggle_technical(state); dirty = true
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = view.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                if hit then
                    status = ""
                    if hit.kind == "node" then model.select_node(state, hit.key); model.set_pane(state, "nodes"); dirty = true
                    elseif hit.kind == "desktop" then model.select_desktop(state, hit.key); model.set_pane(state, "desktops"); dirty = true
                    elseif hit.kind == "open" then perform(open_selected)
                    elseif hit.kind == "control" then ask("control")
                    elseif hit.kind == "observe" then ask("observe")
                    elseif hit.kind == "refresh" then request_refresh()
                    elseif hit.kind == "technical" then model.toggle_technical(state); dirty = true end
                end
            elseif data.type == "mouse" and data.action == "wheel" then
                model.move(state, (data.button == "wheel_up" or data.button == "up") and -1 or 1); dirty = true
            end
        end
    end
    running = false
    updates:close()
    ticker:stop()
    handle:close()
    process.unlisten(states)
    process.unlisten(answers)
    output:close()
    tty.stop()
end
return {main = main}
