-- MIT. The Hive Manager application: named Bees as membership and their
-- owners report them, each node's workspaces as its owner lists them, and
-- explicit control or observe requests confirmed by the viewer. It reads
-- through one typed live directory. It asks this node's supervisor and grants
-- nothing. Opening the manager enables no Hive.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local time = require("time")
local uuid = require("uuid")
local registry = require("registry")
local system = require("system")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local names = require("names")
local layout = require("view")
local directory = require("directory")
local hive = require("hive")
local types = require("types")
local remote = require("remote")
local desktop_protocol = require("desktop_protocol")
local NAMES = "bee.hive_manager:names"
local POLL = "5s"
local CALL_TIMEOUT = "2s"
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
local VIEW_TIMEOUT = "30s"
local function open_directory(handle: hive.Client, open_view: (directory.Attach) -> directory.Outcome): directory.Directory
    return directory.live({
        local_node = own_node(),
        lookup = hive.supervisor,
        membership = function(): (unknown, unknown) return system.cluster.members() end,
        call = function(owner: types.OwnerRef, target: types.Target, input: {[string]: unknown}, options: {timeout: string?}): types.Reply
            return handle:call(owner, target, input, {timeout = options.timeout})
        end,
        open_view = open_view,
        timeout = CALL_TIMEOUT,
    })
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
    local frames = assert(process.listen(desktop_protocol.VIEW_FRAME, {message = true}))
    -- The open remote view, if any: this window draws its rows until it exits.
    local view: remote.View? = nil
    local state: model.State = model.new(model.names(entry_data(NAMES)))
    -- Attach a confirmed request in a view process on the display client host;
    -- the owner node's bridge admits it and leases the workspace's host.
    local function open_view(request: directory.Attach): directory.Outcome
        if view then return {ok = false, code = "BUSY", message = "A remote desktop is already open"} end
        -- A node never admits its own displays as remote clients; this node's
        -- workspaces open in place from the desktop's workspace menu.
        if request.node_id == own_node() then
            return {ok = false, code = "UNSUPPORTED_CAPABILITY", message = "This node's workspaces open from the workspace menu (F9, W)"}
        end
        local view_states, listen_error = process.listen(desktop_protocol.VIEW_STATE, {message = true})
        if not view_states then return {ok = false, code = "UNAVAILABLE", message = tostring(listen_error)} end
        local pid, spawn_error = process.spawn_monitored(desktop_protocol.VIEWER, desktop_protocol.CLIENT_HOST, tostring(process.pid()),
            request.node_id, request.workspace_id, request.mode, width, math.max(1, height - 1))
        if not pid then
            process.unlisten(view_states)
            return {ok = false, code = "UNAVAILABLE", message = "Remote view: " .. tostring(spawn_error)}
        end
        local viewer = tostring(pid)
        local deadline = time.after(VIEW_TIMEOUT)
        local outcome: directory.Outcome? = nil
        while not outcome do
            local selected = channel.select({view_states:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then
                process.send(viewer, desktop_protocol.VIEW_CLOSE, {version = 1})
                outcome = {ok = false, code = "UNCERTAIN", message = "The remote view did not report within " .. VIEW_TIMEOUT .. "; it is closing"}
            elseif tostring(selected.value:from()) == viewer then
                local attached, failed = remote.state(selected.value:payload():data())
                if attached then
                    local node = model.selected(state)
                    view = {pid = viewer, node_id = request.node_id, node_label = node and node.node_id == request.node_id and node.label or request.node_id,
                        workspace_id = attached.workspace_id, desktop_id = attached.desktop_id, mode = attached.mode,
                        session_id = attached.session_id, rows = {}, cursor = nil, leaving = false}
                    outcome = {ok = true, code = "", message = "", session_id = attached.session_id, mode = attached.mode, viewer = viewer}
                else
                    outcome = {ok = false, code = failed and failed.code or "UNAVAILABLE", message = failed and failed.message or "Remote desktop unavailable"}
                end
            end
        end
        process.unlisten(view_states)
        return outcome
    end
    local source = open_directory(handle, open_view)
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid Hive Manager checkpoint") end
    local offset = 0
    local hits: {frame.Hit} = {}
    local status = ""
    local announced = false
    local last_checkpoint = ""
    local running, dirty = true, true
    local dialog: {request_id: string, intent: directory.Attach}? = nil
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
            if not ok then status = "Query failed: " .. tostring(failure)
            elseif status == "Query in progress" then status = "" end
            changed()
        end)
    end
    local started = time.now()
    local supervisor_running = false
    local function refresh_local()
        local supervisor = source:supervisor()
        supervisor_running = supervisor.running
        model.set_supervisor(state, supervisor.running, supervisor.detail)
        local members, problem = source:members()
        model.apply_members(state, members, problem, math.floor(time.now():sub(started):milliseconds()))
        dirty = true
    end
    local function refresh()
        for _, node in ipairs(state.nodes) do
            if not running then return end
            if node.member and not node.client_only then
                if supervisor_running then model.apply_presence(state, node.node_id, source:presence(node.node_id))
                else model.apply_presence(state, node.node_id, types.reply_error("", types.fault("UNAVAILABLE", "no supervisor to ask"))) end
                changed()
            end
        end
        if not running then return end
        local selected = model.selected(state)
        if selected and selected.status == "reachable" then
            model.apply_stats(state, selected.node_id, source:stats(selected.node_id))
            if state.catalogs[selected.node_id] then model.apply_catalog(state, selected.node_id, source:workspaces(selected.node_id, model.query(state, selected.node_id))) end
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
        if selected.client_only then status = "Display client; workspaces run on its Bee node"; dirty = true; return end
        model.apply_catalog(state, selected.node_id, source:workspaces(selected.node_id, model.query(state, selected.node_id)))
        local current = model.selected(state)
        if current and current.node_id == selected.node_id then
            model.set_pane(state, "workspaces")
            model.move(state, 1)
        end
        dirty = true
    end
    local function act(confirmed: directory.Attach)
        local intent: directory.Attach? = model.pending_intent(state)
        local refused: string? = nil
        if intent ~= confirmed then intent, refused = model.confirm_intent(state, confirmed) end
        if not intent then status = refused or ""; dirty = true; return end
        status = ""
        dirty = true
        model.apply_outcome(state, intent, source:attach(intent))
        local selected = model.selected(state)
        if selected then model.apply_catalog(state, selected.node_id, source:workspaces(selected.node_id, model.query(state, selected.node_id))) end
        dirty = true
    end
    -- Control and observation are explicit choices confirmed through the
    -- shell; a selection or a key alone requests nothing of an owner.
    local function ask(mode: directory.Mode)
        if dialog then return end
        local pending = model.pending_intent(state)
        if pending then perform(function() act(pending) end); return end
        local workspace = model.selected_workspace(state)
        local node = model.selected(state)
        if not workspace or not node then status = "Select a workspace first"; dirty = true; return end
        local intent, refused = model.preview_intent(state, mode, uuid.v4())
        if not intent then status = refused or "Workspace unavailable"; dirty = true; return end
        local title = mode == "control" and "Control this workspace here?" or "Observe this workspace here?"
        local workspace_label = workspace.label ~= "" and workspace.label or names.label(workspace.workspace_id)
        local message = model.text("Workspace " .. workspace_label .. " (" .. workspace.workspace_id .. ") on " .. node.label, 512)
        local request_id, err = client.query(launch, {kind = "confirm", title = title, message = message, accept = mode == "control" and "Control" or "Observe"})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, intent = intent}
        dirty = true
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    request_refresh()
    while running do
        local shown = view
        if dirty and shown then
            local drawn = remote.draw(width, height, preferences, shown)
            assert(output:present(drawn.rows, {cursor = drawn.cursor}))
            dirty = false
        elseif dirty then
            local drawn = layout.draw(width, height, preferences, state, offset, status)
            hits = drawn.hits
            offset = drawn.offset
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            local checkpoint = model.checkpoint(state)
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive(), answers:case_receive(), ticks:case_receive(),
            updates:case_receive(), frames:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            local happened = event.value
            if happened.kind == process.event.CANCEL then running = false
            elseif happened.kind == process.event.EXIT and view and tostring(happened.from) == view.pid then
                local result: unknown = happened.result
                local failure = type(result) == "table" and result.error ~= nil and tostring(result.error) or nil
                model.end_session(state, view.node_id, view.workspace_id)
                view = nil
                status = failure and ("Remote desktop ended: " .. failure) or "Remote desktop closed"
                dirty = true
            end
        elseif event.channel == frames then
            local message = event.value
            local current = view
            if current and tostring(message:from()) == current.pid then
                local rows, cursor = remote.frame(message:payload():data())
                if rows then current.rows, current.cursor, dirty = rows, cursor, true end
            end
        elseif view then
            -- The remote view has the window: its input goes to the view.
            local current = view
            if event.channel == input then
                local data = event.value
                if data.type == "close" then running = false
                elseif data.type == "resize" then
                    width, height = data.width, data.height
                    process.send(current.pid, desktop_protocol.VIEW_RESIZE, {version = 1, width = width, height = math.max(1, height - 1)})
                    dirty = true
                else
                    local decision, forwarded = remote.forward(current, data :: {[string]: unknown})
                    if decision == "leave" and not current.leaving then
                        current.leaving = true
                        process.send(current.pid, desktop_protocol.VIEW_CLOSE, {version = 1})
                        dirty = true
                    elseif decision == "forward" and forwarded then
                        process.send(current.pid, desktop_protocol.VIEW_INPUT, {version = 1, event = forwarded})
                    end
                end
            elseif event.channel == states then
                local message = event.value
                if broker and message:from() == broker then
                    local payload: unknown = message:payload():data()
                    local next_preferences = appearance.decode(payload)
                    if next_preferences and type(payload) == "table" and payload.version == 1 then preferences = next_preferences; dirty = true end
                end
            end
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
                if result.action == "accept" then perform(function() act(asked.intent) end) else status = "Cancelled"; dirty = true end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" and state.editing then
                local key = data.key_type
                if key == "enter" then
                    if model.submit(state) then perform(open_selected) end
                elseif key == "esc" or key == "escape" then model.edit(state, false)
                elseif key == "backspace" then model.erase(state)
                elseif type(data.key) == "string" and data.key ~= "" and (key == nil or key == "") then model.type_text(state, data.key) end
                dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                local letter = tostring(data.key or "")
                status = ""
                if state.pane == "workspaces" and (key == "pgup" or key == "pgdown") then
                    if model.page(state, key == "pgdown" and 1 or -1) then perform(open_selected) end
                    dirty = true
                elseif state.pane == "workspaces" and letter == "/" then model.edit(state, true); dirty = true
                elseif key == "up" or letter == "k" then model.move(state, -1); dirty = true
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
                local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                if hit then
                    status = ""
                    if hit.kind == "node" then model.select_node(state, hit.key); model.set_pane(state, "nodes"); dirty = true
                    elseif hit.kind == "workspace" then model.select_workspace(state, hit.key); model.set_pane(state, "workspaces"); dirty = true
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
    local open = view
    if open then process.send(open.pid, desktop_protocol.VIEW_CLOSE, {version = 1}) end
    process.unlisten(frames)
    updates:close()
    ticker:stop()
    handle:close()
    process.unlisten(states)
    process.unlisten(answers)
    output:close()
    tty.stop()
end
return {main = main}
