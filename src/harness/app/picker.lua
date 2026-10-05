-- MIT. The Agent window's selection phase, before any native child exists.
-- It owns the same broker terminal throughout selection and execution.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local funcs = require("funcs")
local bounds = require("bounds")
local client = require("client")
local caller = require("caller")
local appearance = require("appearance")
local input_event = require("input_event")
local sessions = require("sessions")
local admission = require("admission")
local agents = require("agents")
local view = require("view")
local session_view = require("session_view")
local directory_view = require("directory_view")
local sessions_protocol = require("sessions_protocol")
local frame = require("frame")
local forms = require("forms")
local profile_view = require("profile_view")
local terminal_view = require("terminal_view")
local M = {}
type Channel = channel.Channel
-- The form's owner calls run as this Agent's own actor.
local function ask(target: string, request: {[string]: unknown}): caller.Reply
    local raw, err = funcs.call(target, request)
    if err then return caller.unknown() end
    return caller.decode(raw) or caller.unknown()
end
type Loaded = {serial: integer, listing: agents.Listing?, directory: {sessions_protocol.SessionSnapshot}?, workspaces: {[string]: agents.Workspace}?, error: string?}
type Opened = {serial: integer, conversation: agents.Conversation?, error: string?}
type Progress = {conversation: agents.Conversation, error: string?}
local function fault(reply: admission.Reply?): string
    local value = reply and reply.error
    if not value then return "Agent launch was not admitted" end
    return value.code .. ": " .. value.message
end

-- A CLI definition route uses the same setup and admission operations as an
-- explicit picker choice. The command resolver supplies only a definition
-- reference; this actor obtains and fences the current measured plan.
function M.direct(workspace_id: string, definition_ref: string, thread_id: string?,
    origin_view: {view_id: string, instance_id: string}?): (admission.Admitted?, string?)
    local plan, refused = admission.resolve(definition_ref, "window", workspace_id)
    if not plan then return nil, fault(refused) end
    local setup, setup_error = funcs.call("bee.harness.binding:setup", {
        workspace_id = workspace_id, definition_ref = definition_ref,
        expected_plan_digest = plan.plan_digest})
    local prepared = bounds.object(setup)
    if setup_error or not prepared or prepared.ok ~= true then
        return nil, setup_error and tostring(setup_error) or
            (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")
    end
    local request_id, request_error = uuid.v7()
    if not request_id then return nil, "Agent request identity: " .. tostring(request_error) end
    local admitted, admission_error = admission.admit_request({request_id = request_id,
        definition_ref = definition_ref, expected_plan_digest = plan.plan_digest,
        workspace_id = workspace_id, thread_id = thread_id, brief = "", mode = "window", workdir = prepared.workdir, origin_view = origin_view})
    if not admitted then return nil, fault(admission_error) end
    return admitted, nil
end

function M.run(launch: client.Launch, input: tty.EventChannel, lifecycle: Channel<process.Event>,
    closes: Channel<process.Message>): (admission.Admitted?, string?)
    local states = assert(process.listen(appearance.TOPIC, {message = true}))
    local navigation = assert(process.listen("bee.app.navigate", {message = true}))
    local output = assert(tty.surface())
    local running = true
    local load_serial = 0
    local loads = channel.new(1)
    local loads_pending: {[integer]: Loaded} = {}
    local function send_loads(value: Loaded)
        loads_pending[value.serial] = value
        loads:send(value.serial)
    end
    local ticker: time.Ticker? = time.ticker("1s")
    local function finish(admitted: admission.Admitted?, err: string?): (admission.Admitted?, string?)
        running = false
        load_serial = load_serial + 1
        process.unlisten(states)
        process.unlisten(navigation)
        if ticker then ticker:stop(); ticker = nil end
        local closed, close_error = output:close()
        return admitted, not closed and ("Close profile screen: " .. tostring(close_error)) or err
    end
    local width, height = tty.screen_size()
    local preferences = launch.appearance
    local function no_agents(): agents.Listing return {items = {}, unavailable = 0, notes = {}} end
    local directory: {sessions_protocol.SessionSnapshot} = {}
    local workspace_names: {[string]: agents.Workspace} = {}
    local query = ""
    local sort: "name" | "driver" = "name"
    local searching = false
    local catalog_open = false
    local filtered = false
    local remembered: {[string]: agents.Conversation} = {}
    local listed = no_agents()
    local selected: integer = 0
    local status = "Loading sessions…"
    local loading = false
    local show_unavailable = false
    local show_closed = false
    local clicks = frame.clicks()
    local conversation: agents.Conversation? = nil
    local draft = ""
    local confirming = ""
    local session_busy = false
    local session_frame: session_view.Frame = {rows = {}, hits = {}}
    local menu = frame.menu()
    local ticks = 0
    local opening = false
    local open_serial = 0
    local opens = channel.new(1)
    local progress = channel.new(1)
    local open_key, open_target = "", ""
    local close_key: string? = nil
    local reload_pending = false
    local request_id: string? = nil
    local request_definition, request_plan = "", ""
    local editing: profile_view.State? = nil
    local edit_frame: profile_view.Frame = {rows = {}, hits = {}}
    local attachment_error: string? = nil
    local announced = false
    local dirty = true
    local drawn: view.Frame = {rows = {}, hits = {}, capacity = 0, offset = 0}
    -- directory_loaded reads the sessions and the workspaces they live in.
    local function directory_loaded(serial: integer, workspace_filter: string?, closed_requested: boolean): Loaded
        local rows, load_error = agents.directory(sessions.client(), workspace_filter, closed_requested)
        local names: {[string]: agents.Workspace} = {}
        local own = agents.workspace(launch.workspace_id, ask)
        if own then names[launch.workspace_id] = own end
        for _, row in ipairs(rows or {}) do
            local id = agents.home(row.session)
            if id and not names[id] then names[id] = agents.workspace(id, ask) end
        end
        return {serial = serial, directory = rows, workspaces = names, error = load_error}
    end
    local function load()
        if loading then reload_pending = true; return end
        load_serial = load_serial + 1
        local serial = load_serial
        loading = true
        status = catalog_open and "Loading agents…" or "Loading sessions…"
        dirty = true
        local include = show_unavailable
        local catalog_requested = catalog_open
        local catalog_query, catalog_sort = query, sort
        local workspace_filter = filtered and launch.workspace_id or nil
        local closed_requested = show_closed
        coroutine.spawn(function()
            if catalog_requested then
                local found, load_error = agents.list(sessions.client(), include, catalog_query, catalog_sort)
                if running and serial == load_serial then
                    local sent: Loaded = {serial = serial, listing = found, error = load_error}
                    send_loads(sent)
                end
            else
                local sent = directory_loaded(serial, workspace_filter, closed_requested)
                if running and serial == load_serial then send_loads(sent) end
            end
        end)
    end
    -- close_listed closes the session at index, then lists the sessions again.
    local function close_listed(index: integer)
        local entry = directory[index]
        if not entry or loading then return end
        load_serial = load_serial + 1
        local serial = load_serial
        loading = true
        status = "Closing session…"
        dirty = true
        local workspace_filter = filtered and launch.workspace_id or nil
        local closed_requested = show_closed
        coroutine.spawn(function()
            local _, fault = sessions.client():close({session = entry.session, operation_key = assert(uuid.v7())})
            local sent = directory_loaded(serial, workspace_filter, closed_requested)
            if fault then sent.error = fault.message end
            if running and serial == load_serial then send_loads(sent) end
        end)
    end
    local function idle(): boolean return not opening end
    local queued_tasks: {(agents.Conversation) -> ()} = {}
    local queued_text: string? = nil
    local function start_task(task: (agents.Conversation) -> ())
        local current = conversation
        if not current or opening then return end
        if session_busy then queued_tasks[#queued_tasks + 1] = task; return end
        session_busy = true
        dirty = true
        coroutine.spawn(function()
            local ok, task_error = pcall(task, current)
            progress:send({conversation = current, error = not ok and tostring(task_error) or nil})
        end)
    end
    local function leave_session()
        conversation, draft, status, session_busy = nil, "", "", false
        queued_tasks, queued_text = {}, nil
        catalog_open = false
        client.title(launch, "Sessions")
        load()
        dirty = true
    end
    local function start_from_session()
        local current = conversation
        local definition = current and current.session.snapshot.definition
        if not current or not definition or opening then return end
        open_serial = open_serial + 1
        local serial = open_serial
        local key = assert(uuid.v7())
        opening = true; status = "Opening new session…"; dirty = true
        coroutine.spawn(function()
            local conv, err = agents.reopen(sessions.client(), current.session.snapshot, key)
            if running and serial == open_serial then opens:send({serial = serial, conversation = conv, error = err}) end
        end)
    end
    local function submit()
        if conversation and conversation.lifecycle ~= "active" then status = "This session is closed to new work. Esc returns to Sessions."; dirty = true; return end
        local text = draft
        if text == "" or queued_text == text then return end
        queued_text = text
        start_task(function(current: agents.Conversation)
            queued_text = nil
            if agents.submit(current, text, function(): string return assert(uuid.v7()) end) then
                if draft == text then draft = "" end
                agents.refresh(current)
            end
        end)
    end
    local function setup_agent()
        local entry = listed.items[selected]
        if entry and not entry.ready then status = "Setup: " .. entry.reason .. ". Install or sign in with the provider, then R refresh."; dirty = true end
    end
    local function close_session()
        start_task(function(current: agents.Conversation)
            close_key = close_key or assert(uuid.v7())
            if agents.close(current, close_key) then agents.refresh(current) end
        end)
    end
    local function stop_work()
        start_task(function(current: agents.Conversation)
            agents.stop(current, function(): string return assert(uuid.v7()) end)
        end)
    end
    local function open_existing(index: integer)
        local entry = directory[index]
        if not entry or opening then return end
        open_serial = open_serial + 1
        local serial = open_serial
        opening = true; status = "Opening session…"; dirty = true
        coroutine.spawn(function()
            local conv, err = agents.resume(sessions.client(), entry.session)
            local saved = remembered[entry.session]
            if conv and saved then conv = agents.remember(conv, saved) end
            if running and serial == open_serial then
                local reply: Opened = {serial = serial, conversation = conv, error = err}
                opens:send(reply)
            end
        end)
    end
    if launch.arguments[1] == "--session" then
        local target = sessions_protocol.ref("session", launch.arguments[2])
        if target then
            open_serial = open_serial + 1
            local serial = open_serial
            opening = true
            coroutine.spawn(function()
                local conv, err = agents.resume(sessions.client(), target)
                if running and serial == open_serial then opens:send({serial = serial, conversation = conv, error = err}) end
            end)
        else status = "Invalid session target" end
    end
    while true do
        if dirty then
            local rows: {string}
            if editing then
                edit_frame = profile_view.draw(width, height, preferences, editing)
                frame.render(edit_frame, menu, preferences)
                rows = edit_frame.rows
            elseif conversation then
                session_frame = session_view.draw(width, height, preferences, conversation, draft, status, directory)
                frame.render(session_frame, menu, preferences)
                rows = session_frame.rows
            elseif not catalog_open then
                drawn = directory_view.draw(width, height, preferences, directory, selected, status, filtered, workspace_names, show_closed)
                frame.render(drawn, menu, preferences)
                rows = drawn.rows
            else
                drawn = view.draw(width, height, preferences, listed, selected, status, opening, show_unavailable, query, sort, searching)
                frame.render(drawn, menu, preferences)
                rows = drawn.rows
            end
            assert(output:present(rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch, {negotiate_close = true}); announced = true end
            dirty = false
        end
        if load_serial == 0 then load() end
        local cases = {input = input:case_receive(), lifecycle = lifecycle:case_receive(), closes = closes:case_receive(),
            states = states:case_receive(), navigation = navigation:case_receive(), loads = loads:case_receive(),
            opens = opens:case_receive(), progress = progress:case_receive()}
        if ticker then cases.ticks = ticker:channel():case_receive() end
        local event = channel.select(cases)
        if not event.ok then return finish(nil, nil) end
        local refresh = false
        local edit, duplicate = false, false
        local open = false
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then return finish(nil, nil) end
        elseif event.channel == closes then
            local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
            if close then client.close_reply(launch, close.request_id, {action = "accept"}); return finish(nil, nil) end
        elseif event.channel == navigation then
            local args = client.navigation(launch, tostring(event.value:from()), event.value:payload():data())
            local target = args and args[1] == "--session" and sessions_protocol.ref("session", args[2]) or nil
            if target and not opening then
                open_serial = open_serial + 1
                local serial = open_serial
                opening = true; status = "Opening session…"; dirty = true
                coroutine.spawn(function()
                    local conv, err = agents.resume(sessions.client(), target)
                    if running and serial == open_serial then opens:send({serial = serial, conversation = conv, error = err}) end
                end)
            end
        elseif event.channel == states then
            if event.value:from() == launch.broker_pid then
                local payload: unknown = event.value:payload():data()
                local decoded = type(payload) == "table" and appearance.decode(payload.appearance) or nil
                if decoded then preferences = decoded; dirty = true end
            end
        elseif event.channel == loads then
            local serial = event.value
            if type(serial) ~= "number" then error("invalid completion identity") end
            local result = assert(loads_pending[math.floor(serial)], "missing completion")
            loads_pending[math.floor(serial)] = nil
            if result.serial == load_serial then
                loading = false
                listed = no_agents()
                if result.listing then listed = result.listing end
                directory = result.directory or directory
                workspace_names = result.workspaces or workspace_names
                local count = catalog_open and #listed.items or #directory
                selected = math.floor(math.min(math.max(1, selected), count))
                status = result.error or attachment_error or listed.notes[1] or ""
                dirty = true
                if reload_pending then reload_pending = false; load() end
            end
        elseif event.channel == opens then
            local result = event.value
            if result.serial == open_serial then
                opening = false
                if result.conversation then
                    if result.conversation.session.snapshot.terminal == true then
                        output:close()
                        local closing, view_error = terminal_view.run(launch, result.conversation.session:ref(), input, lifecycle, closes)
                        if closing then return finish(nil, view_error) end
                        output = assert(tty.surface())
                        leave_session()
                        attachment_error = view_error
                        status = view_error or ""
                        goto next_iteration
                    end
                    open_target = ""
                    conversation, draft, status, close_key, session_busy = result.conversation, "", "", nil, false
                    local ref = result.conversation.session:ref()
                    remembered[ref] = result.conversation
                    local found = false
                    for index, row in ipairs(directory) do
                        if row.session == ref then directory[index] = result.conversation.session.snapshot; found = true; break end
                    end
                    if not found then directory[#directory + 1] = result.conversation.session.snapshot end
                    ticks = 0
                    if ticker then ticker:stop() end
                    ticker = time.ticker("1s")
                    client.title(launch, conversation.title)
                else
                    status = result.error or "Agent session did not open"
                end
                dirty = true
            end
        elseif event.channel == progress then
            local result = event.value
            if conversation and result.conversation == conversation then
                session_busy = false; dirty = true
                for index, row in ipairs(directory) do
                    if row.session == conversation.session:ref() then directory[index] = conversation.session.snapshot end
                end
                client.title(launch, conversation.title)
                if result.error then status = "Session operation failed: " .. result.error end
                local next_task = table.remove(queued_tasks, 1)
                if next_task then start_task(next_task) end
            end
        elseif ticker and event.channel == ticker:channel() then
            local shown = conversation
            ticks = ticks + 1
            if not catalog_open and not editing and ticks % 5 == 0 then load() end
            if shown and not session_busy and (agents.pending(shown) or shown.activity ~= "idle" or ticks % 5 == 0) then
                start_task(function(current: agents.Conversation) agents.refresh(current) end)
            end
        else
            local data = input_event.decode(event.value)
            if data then
                local routed, handled = frame.route(menu, data, editing ~= nil or conversation ~= nil)
                if handled then dirty = true end
                data = routed
            end
            if data then
                if data.type == "close" then return finish(nil, nil)
                elseif data.type == "start" or data.type == "resize" then
                    width, height = assert(data.width), assert(data.height); dirty = true
                elseif editing then
                    local action = profile_view.input(editing, data, edit_frame)
                    if action == "cancel" then editing = nil
                    elseif action == "copy" then
                        local ok, err = forms.copy(editing.form)
                        if ok then ok, err = forms.save(editing.form) end
                        if ok then editing = nil; refresh = true else editing.status = err or "Copy failed" end
                    elseif action == "reload" then
                        local form, err = forms.reload(editing.form)
                        if form then editing = profile_view.new(form, ask) else editing.status = err or "Reload failed" end
                    elseif action == "save" or action == "remove" then
                        local ok: boolean = false
                        local err: string? = nil
                        if action == "save" then ok, err = forms.save(editing.form)
                        else ok, err = forms.remove(editing.form) end
                        if ok then editing = nil; refresh = true
                        else editing.status = err or "Profile operation failed" end
                    end
                    dirty = true
                elseif conversation then
                    if data.type == "key" and data.action == "press" and (data.key_type == "escape" or data.key_type == "esc") then
                        if confirming ~= "" then confirming = ""; status = ""; dirty = true else leave_session() end
                    elseif data.type == "key" and data.action == "press" and data.key_type == "enter" then
                        if confirming == "stop" then confirming = ""; status = ""; stop_work()
                        elseif confirming == "close" then confirming = ""; status = ""; close_session()
                        elseif conversation.lifecycle == "closed" then start_from_session()
                        else submit() end
                    elseif data.type == "key" and data.action == "press" and data.ctrl and data.key == "d" then conversation.details = not conversation.details; dirty = true
                    elseif data.type == "key" and data.action == "press" and data.ctrl and data.key == "x" then confirming = "close"; status = "Close session? Accepted work finishes; new work is refused. Enter confirms · Esc keeps it"; dirty = true
                    elseif data.type == "key" and data.action == "press" and data.ctrl and data.key == "k" then confirming = "stop"; status = "Stop current work? Session stays available. Enter confirms · Esc keeps it"; dirty = true
                    elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                        local hit = frame.hit(session_frame.hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                        local kind = hit and hit.kind or ""
                        if kind == "sidebar_session" and hit and not session_busy then
                            selected = hit.index; open_existing(selected)
                        elseif kind == "back" then leave_session()
                        elseif kind == "details" then conversation.details = not conversation.details; dirty = true
                        elseif kind == "new_from_session" then start_from_session()
                        elseif kind == "send" then submit()
                        elseif kind == "close_session" then confirming = "close"; status = "Close session? Enter confirms · Esc keeps it"; dirty = true
                        elseif kind == "stop_work" then confirming = "stop"; status = "Stop current work? Enter confirms · Esc keeps it"; dirty = true end
                    else
                        local next_draft = session_view.edit(draft, data)
                        if next_draft ~= draft then draft = next_draft; dirty = true end
                    end
                elseif not catalog_open then
                    local kind = ""
                    if data.type == "key" and data.action == "press" then
                        local key = data.key:lower()
                        if confirming == "close_listed" then
                            if data.key_type == "enter" then confirming = ""; close_listed(selected)
                            elseif data.key_type == "esc" or data.key_type == "escape" then confirming = ""; status = ""; dirty = true end
                        elseif data.key_type == "up" then selected = math.floor(math.max(1, selected - 1)); dirty = true
                        elseif data.key_type == "down" then selected = math.floor(math.min(#directory, selected + 1)); dirty = true
                        elseif data.key_type == "enter" then open = true
                        elseif key == "n" then kind = "new_session"
                        elseif key == "x" then kind = "close_listed"
                        elseif key == "c" then kind = "closed"
                        elseif key == "w" then kind = "workspace"
                        elseif key == "r" then refresh = true
                        elseif data.key_type == "esc" or data.key_type == "escape" then return finish(nil, nil) end
                    elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                        local hit = frame.hit(drawn.hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                        kind = hit and hit.kind or ""
                        if kind == "session" and hit then
                            selected = hit.index; dirty = true
                            if frame.double_click(clicks, kind, hit.index, time.now():unix_nano() // 1000000) then open = true end
                        elseif kind == "open" then open = true
                        elseif kind == "refresh" then refresh = true end
                    end
                    if kind == "new_session" then catalog_open = true; selected = 0; refresh = true
                    elseif kind == "close_listed" and directory[selected] and directory[selected].lifecycle ~= "closed" and directory[selected].lifecycle ~= "closing" then
                        confirming = "close_listed"
                        status = "Close " .. directory[selected].title .. "? Accepted work finishes first. Enter confirms · Esc keeps it"
                        dirty = true
                    elseif kind == "closed" then show_closed = not show_closed; refresh = true
                    elseif kind == "workspace" then filtered = not filtered; refresh = true end
                elseif data.type == "key" and data.action == "press" then
                    if searching then
                        if data.key_type == "escape" or data.key_type == "esc" or data.key_type == "enter" then searching = false; dirty = true
                        elseif data.key_type == "backspace" then query = query:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""); refresh = true
                        elseif not data.ctrl and not data.alt and (data.key_type == "char" or data.key_type == "rune") and #query + #data.key <= 256 then query = query .. data.key; refresh = true end
                    elseif data.ctrl and data.key:lower() == "s" then sort = sort == "name" and "driver" or "name"; refresh = true
                    elseif data.key == "/" then searching = true; dirty = true
                    elseif data.key_type == "escape" or data.key_type == "esc" then catalog_open = false; refresh = true
                    elseif data.key_type == "up" and selected > 0 and idle() then selected = math.floor(math.max(1, selected - 1)); dirty = true
                    elseif data.key_type == "down" and selected > 0 and idle() then selected = math.floor(math.min(#listed.items, selected + 1)); dirty = true
                    elseif data.key_type == "enter" and idle() then
                        local entry = listed.items[selected]
                        if entry and not entry.ready then setup_agent() else open = true end
                    elseif data.ctrl or data.alt then
                    elseif data.key:lower() == "u" and idle() then show_unavailable = not show_unavailable; refresh = true
                    elseif data.key:lower() == "r" and idle() then refresh = true
                    elseif data.key:lower() == "s" and idle() then setup_agent()
                    elseif data.key:lower() == "e" and idle() then edit = true
                    elseif data.key:lower() == "n" and idle() then edit = true; duplicate = true end
                elseif data.type == "mouse" then
                    if data.action == "wheel" then
                        if selected > 0 and idle() then
                            local delta = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                            selected = math.floor(math.max(1, math.min(#listed.items, selected + delta))); dirty = true
                        end
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(drawn.hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                        local kind = hit and hit.kind or ""
                        if kind == "close" then catalog_open = false; refresh = true
                        elseif kind == "search" then searching = true; dirty = true
                        elseif kind == "sort" then sort = sort == "name" and "driver" or "name"; refresh = true
                        elseif kind == "setup" then setup_agent()
                        elseif kind == "open" then open = true
                        elseif kind == "unavailable" and idle() then show_unavailable = not show_unavailable; refresh = true
                        elseif kind == "refresh" then refresh = true
                        elseif kind == "edit" then edit = true
                        elseif kind == "new" then edit = true; duplicate = true
                        elseif hit and kind == "choice" and idle() and listed.items[hit.index] then
                            selected = hit.index; dirty = true
                            if frame.double_click(clicks, kind, hit.index, time.now():unix_nano() // 1000000) then
                                if listed.items[selected].ready then open = true else setup_agent() end
                            end
                        end
                    end
                end
            end
        end
        if open and not catalog_open and not conversation and idle() and not loading then open_existing(selected) end
        if edit and catalog_open and not conversation then
            local entry = listed.items[selected]
            if entry then
                local subject: forms.Subject = {title = entry.title}
                if entry.kind == "definition" then subject.definition_ref = entry.ref
                else subject.saved_profile_id, subject.saved_profile_revision = entry.ref, entry.revision end
                local opened, open_error = forms.load(launch.workspace_id, subject, duplicate)
                if opened then editing = profile_view.new(opened, ask)
                else status = open_error or "Profile could not be opened" end
                dirty = true
            end
        end
        if open and catalog_open and not conversation and not loading and idle() and drawn.capacity > 0 then
            local entry = listed.items[selected]
            if entry and entry.ready then
                local target = entry.kind .. ":" .. entry.ref .. ":" .. tostring(entry.revision)
                if open_target ~= target then open_key, open_target = assert(uuid.v7()), target end
                open_serial = open_serial + 1
                local serial = open_serial
                local key = open_key
                opening = true
                status = "Opening session…"
                dirty = true
                coroutine.spawn(function()
                    local definition = entry.ref
                    local profile: {id: string, revision: integer}? = nil
                    if entry.kind == "profile" then
                        local revision = entry.revision or 0
                        local saved, saved_error = forms.saved(launch.workspace_id, entry.ref, revision)
                        if not saved then
                            if running and serial == open_serial then
                                local reply: Opened = {serial = serial, error = saved_error}
                                opens:send(reply)
                            end
                            return
                        end
                        definition, profile = saved.definition_ref, {id = entry.ref, revision = revision}
                    end
                    local opened, open_error = agents.open(sessions.client(), definition, profile, key)
                    if running and serial == open_serial then
                        local reply: Opened = {serial = serial, conversation = opened, error = open_error}
                        opens:send(reply)
                    end
                end)
            end
        end
        if refresh then
            load()
        end
        ::next_iteration::
    end
end
return M
