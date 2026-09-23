-- MIT. The approvals inbox application: the local viewer's requests from
-- the approval owner, explicit decisions through the owner under the
-- viewed revision, conflicts shown as the owner committed them, unknown
-- answers recovered by reading. Local state is the selection, the detail
-- toggle and one in-flight request; closing the app decides nothing.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local funcs = require("funcs")
local registry = require("registry")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local view = require("view")
local inbox = require("inbox")
local caller = require("caller")
local feeds = require("feeds")
local source_config = require("source_config")
local hive = require("hive")
local hive_types = require("hive_types")
local WORKSPACES = "bee.inbox:workspaces"
local POLL = "2s"
type FeedSource = {id: string, node_id: string, workspace_id: string, local_owner: boolean, feed: string}
local function unknown_answer(): model.Reply
    return caller.unknown()
end
local function admitted_workspaces(): unknown
    local entry = registry.get(WORKSPACES)
    if not entry or type(entry.data) ~= "table" then return nil end
    return (entry.data :: {[string]: unknown}).workspaces
end
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local answers = assert(process.listen("bee.application.query.result", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local local_node = hive_types.pid_parts(tostring(process.pid()))
    if not local_node then error("inbox native node identity is unavailable") end
    local mesh, mesh_error = hive.open()
    if not mesh then error(mesh_error or "inbox Hive listener unavailable") end
    local source_entry = registry.get("bee.inbox:sources")
    local declared: unknown = nil
    if source_entry and type(source_entry.data) == "table" then declared = source_entry.data.sources end
    local local_workspaces = inbox.workspaces(launch.workspace_id, admitted_workspaces())
    local configured, configure_error = source_config.configure(local_node, local_workspaces, declared)
    if not configured then error(configure_error or "inbox source configuration is invalid") end
    local routed = feeds.new(configured,
        function(source: FeedSource, target: string, request: unknown): (unknown, string?)
            if source.local_owner then return funcs.new():call(target, request) end
            if type(request) ~= "table" then return nil, "invalid owner request" end
            local answer = mesh:call({node_id = source.node_id, service_id = "bee.approvals.binding"},
                {operation_ref = target}, request :: {[string]: unknown}, {timeout = "5s"})
            if not answer.ok then
                -- Transport failure cannot say whether an owner mutation committed.
                if target == "bee.approvals.binding:decide" or target == "bee.approvals.binding:withdraw" then
                    return nil, "owner outcome unknown"
                end
                return {ok = false, error = answer.error, value = nil, replayed = false}, nil
            end
            return answer.value, nil
        end)
    -- feeds owns source-address routing.  Wrap its reply-shaped result in the
    -- standard caller boundary so the application itself never trusts a
    -- transport value without the shared decoder.
    local owner = caller.new(function(target: string, request: unknown): (unknown, string?)
        return routed:invoke(target, request), nil
    end)
    local state: model.State = model.new(configured.workspaces)
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid inbox checkpoint") end
    local rows: {model.Row} = {}
    local offset = 0
    local hits: {frame.Hit} = {}
    local status = ""
    local announced = false
    local last_checkpoint = ""
    local running, dirty = true, true
    local updates = channel.new(1)
    local busy = false
    local function perform(operation: () -> ())
        if busy then status = "Sync in progress"; dirty = true; return end
        busy = true
        coroutine.spawn(function()
            local ok, failure = pcall(operation)
            busy = false
            if not running then return end
            if not ok then status = "Owner query failed: " .. tostring(failure)
            elseif status == "Sync in progress" then status = "" end
            dirty = true
            updates:send(true)
        end)
    end
    -- One dialog at a time: what it asks and what accepting it does.
    local dialog: {request_id: string, kind: string, confirmation: model.Confirmation}? = nil
    local ticker = assert(time.ticker(POLL))
    local ticks = ticker:channel()
    local function refresh()
        for _, workspace in ipairs(state.workspaces) do
            if not running then return end
            local pages = 0
            local more = true
            local name: string = workspace
            while more and pages < 8 do
                local intent = model.inbox_intent(state, name)
                local answer: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
                more = model.apply_inbox(state, name, answer)
                pages = pages + 1
            end
        end
        rows = model.rows(state)
        dirty = true
    end
    local function open_selected()
        local intent = model.read_intent(state)
        if not intent then return end
        local reply: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
        model.apply_read(state, tostring(intent.request.approval_id), reply)
        rows = model.rows(state)
        dirty = true
    end
    -- An answer that never arrived is recovered from the owner's record.
    local function recover()
        local intent = model.recovery_intent(state)
        if not intent then return end
        local reply: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
        model.apply_recovery(state, reply)
        rows = model.rows(state)
        dirty = true
    end
    local function act(kind: string)
        local request_id = uuid.v7()
        local intent: model.Intent? = nil
        local refused: string? = nil
        if kind == "withdraw" then intent, refused = model.withdraw_intent(state, request_id)
        else intent, refused = model.decision_intent(state, request_id, kind == "approve" and "approved" or "denied") end
        if not intent then status = refused or ""; dirty = true; return end
        status = ""
        dirty = true
        local reply = owner:invoke(intent.target, intent.request)
        model.apply_answer(state, request_id, reply)
        if not reply then recover() end
        rows = model.rows(state)
        dirty = true
    end
    -- Every decision passes through the shell's confirmation; nothing acts
    -- on a row selection or a key alone.
    local function ask(kind: string)
        if dialog or state.pending or busy then return end
        local selected = model.selected_row(state)
        local confirmation = model.confirmation(state)
        if not selected or not confirmation then status = "Open a pending request before deciding"; dirty = true; return end
        local title = kind == "approve" and "Approve this request?" or (kind == "deny" and "Deny this request?" or "Withdraw this request?")
        local message = model.text(selected.effect .. " on " .. selected.target .. " for " .. selected.requester_id, 512)
        local accept = kind == "approve" and "Approve" or (kind == "deny" and "Deny" or "Withdraw")
        local request_id, err = client.query(launch, {kind = "confirm", title = title, message = message, accept = accept})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, kind = kind, confirmation = confirmation}
        dirty = true
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    perform(function()
        refresh()
        if state.selected and state.rows[state.selected :: string] then open_selected() elseif state.selected then model.select(state, nil) end
    end)
    while running do
        if dirty then
            local frame = view.draw(width, height, preferences, state, rows, offset, status)
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
            if not busy then
                if state.pending then perform(recover) else perform(refresh) end
            end
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
                if result.action ~= "accept" then status = "Cancelled"; dirty = true
                elseif not model.confirmation_matches(state, asked.confirmation) then
                    status = "Request changed; open it and confirm again"; dirty = true
                else perform(function()
                    if model.confirmation_matches(state, asked.confirmation) then act(asked.kind)
                    else status = "Request changed; open it and confirm again"; dirty = true end
                end) end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                local text = tostring(data.key or "")
                status = ""
                if key == "up" or text == "k" then model.move(state, -1); dirty = true
                elseif key == "down" or text == "j" then model.move(state, 1); dirty = true
                elseif key == "pgup" then model.move(state, -8); dirty = true
                elseif key == "pgdown" then model.move(state, 8); dirty = true
                elseif key == "enter" or text == "o" then perform(open_selected)
                elseif text == "a" then ask("approve")
                elseif text == "d" then ask("deny")
                elseif text == "w" then ask("withdraw")
                elseif text == "r" then perform(function() if state.pending then recover() else refresh() end end)
                elseif text == "t" then model.toggle_technical(state); dirty = true
                elseif key == "esc" or key == "escape" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                if hit then
                    status = ""
                    if hit.kind == "row" then
                        local row = rows[hit.index]
                        if row then model.select(state, row.approval_id); dirty = true end
                    elseif hit.kind == "open" then perform(open_selected)
                    elseif hit.kind == "approve" or hit.kind == "deny" or hit.kind == "withdraw" then ask(hit.kind)
                    elseif hit.kind == "refresh" then perform(function() if state.pending then recover() else refresh() end end)
                    elseif hit.kind == "technical" then model.toggle_technical(state); dirty = true end
                end
            elseif data.type == "mouse" and data.action == "wheel" then
                model.move(state, (data.button == "wheel_up" or data.button == "up") and -1 or 1); dirty = true
            end
        end
    end
    ticker:stop()
    mesh:close()
    process.unlisten(states)
    process.unlisten(answers)
    output:close()
    tty.stop()
end
return {main = main}
