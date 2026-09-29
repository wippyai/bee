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
local frame = require("frame")
local forms = require("forms")
local profile_view = require("profile_view")
local M = {}
type Channel = channel.Channel
-- The form's owner calls run as this Agent's own actor.
local function ask(target: string, request: {[string]: unknown}): caller.Reply
    local raw, err = funcs.call(target, request)
    if err then return caller.unknown() end
    return caller.decode(raw) or caller.unknown()
end
type Activation = {serial: integer, admitted: admission.Admitted?, refused: admission.Reply?, error: string?, title: string?}
-- A saved profile's launch choices resolved for a manual attach.
type Choice = {definition_ref: string, title: string, plan_digest: string, saved_profile_id: string?,
    saved_profile_revision: integer?, workdir: {root_ref: string, path: string}?, thread_id: string?}
type Setup = {serial: integer, request_id: string, choice: Choice}
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
    local setup, setup_error = funcs.call("bee.harness.launch:setup", {
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
        workspace_id = workspace_id, thread_id = thread_id, brief = "", mode = "window", origin_view = origin_view})
    if not admitted then return nil, fault(admission_error) end
    return admitted, nil
end

function M.run(launch: client.Launch, input: tty.EventChannel, lifecycle: Channel<process.Event>,
    closes: Channel<process.Message>): (admission.Admitted?, string?, boolean?, Channel<Activation>?)
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local output = assert(tty.surface())
    local running = true
    local load_serial = 0
    local loads = channel.new(1)
    local activation_serial = 0
    local activations = channel.new(1) :: Channel<Activation>
    local activating = false
    local setup_future: funcs.Future? = nil
    local setup_response: Channel<unknown>? = nil
    local setup_request: Setup? = nil
    local ticker: time.Ticker? = nil
    -- The surface may close while setup or admission is executing. Setup can
    -- be cancelled before it acquires attempt authority; once admission has
    -- begun, hand its one completion channel to the runtime so it can revoke
    -- authority obtained before the cancellation.
    local function finish(admitted: admission.Admitted?, err: string?): (admission.Admitted?, string?, boolean?, Channel<Activation>?)
        local pending = activating
        local setup_pending = setup_future ~= nil
        running = false
        load_serial = load_serial + 1
        process.unlisten(states)
        if ticker then ticker:stop(); ticker = nil end
        local closed, close_error = output:close()
        local failure = not closed and ("Close profile screen: " .. tostring(close_error)) or err
        if setup_future then
            -- Setup only associates durable roots and definitions. It has not
            -- acquired attempt authority yet, so cancellation lets the
            -- visible owner leave immediately; the completion coroutine will
            -- observe running=false before admission.
            setup_future:cancel()
            setup_future = nil
        end
        setup_response, setup_request = nil, nil
        if pending and not setup_pending then return nil, failure, true, activations end
        activation_serial = activation_serial + 1
        return admitted, failure, nil, nil
    end
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local function no_agents(): agents.Listing return {items = {}, unavailable = 0, notes = {}} end
    local listed = no_agents()
    local selected: integer = 0
    local status = "Loading agents…"
    local loading = false
    local show_unavailable = false
    local conversation: agents.Conversation? = nil
    local draft = ""
    local session_busy = false
    local session_frame: {hits: {frame.Hit}} = {hits = {}}
    local ticks = 0
    local opening = false
    local open_serial = 0
    local opens = channel.new(1) :: Channel<Opened>
    local progress = channel.new(1) :: Channel<Progress>
    local open_key, open_target = "", ""
    local close_key: string? = nil
    local reload_pending = false
    local request_id: string? = nil
    local request_definition, request_plan = "", ""
    local editing: profile_view.State? = nil
    local edit_frame: profile_view.Frame = {rows = {}, hits = {}}
    local announced = false
    local dirty = true
    local drawn: view.Frame = {rows = {}, hits = {}, capacity = 0, offset = 0}
    local function load()
        if loading then reload_pending = true; return end
        load_serial = load_serial + 1
        local serial = load_serial
        loading = true
        listed = no_agents()
        selected = 0
        status = "Loading agents…"
        dirty = true
        local include = show_unavailable
        coroutine.spawn(function()
            local found, load_error = agents.list(sessions.client(), include)
            if running and serial == load_serial then
                loads:send({serial = serial, listing = found, error = load_error})
            end
        end)
    end
    local function idle(): boolean return not activating and not opening end
    local function start_task(task: (agents.Conversation) -> ())
        local current = conversation
        if not current or session_busy then return end
        session_busy = true
        dirty = true
        coroutine.spawn(function()
            task(current)
            progress:send({conversation = current})
        end)
    end
    local function leave_session()
        if ticker then ticker:stop(); ticker = nil end
        conversation, draft, status, session_busy = nil, "", "", false
        client.title(launch, "Agent")
        dirty = true
    end
    local function submit()
        local text = draft
        if text == "" then return end
        start_task(function(current: agents.Conversation)
            if agents.submit(current, text, function(): string return assert(uuid.v7()) end) then
                if draft == text then draft = "" end
                agents.refresh(current)
            end
        end)
    end
    local function close_session()
        start_task(function(current: agents.Conversation)
            close_key = close_key or assert(uuid.v7())
            if agents.close(current, close_key) then agents.refresh(current) end
        end)
    end
    process.send(launch.broker_pid, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"})
    while true do
        if dirty then
            local rows: {string}
            if editing then
                edit_frame = profile_view.draw(width, height, preferences, editing)
                rows = edit_frame.rows
            elseif conversation then
                local shown = session_view.draw(width, height, preferences, conversation, draft, status)
                session_frame = shown
                rows = shown.rows
            else
                drawn = view.draw(width, height, preferences, listed, selected, status, activating or opening, show_unavailable)
                rows = drawn.rows
            end
            assert(output:present(rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch, {negotiate_close = true}); announced = true end
            dirty = false
        end
        if load_serial == 0 then load() end
        local cases = {input = input:case_receive(), lifecycle = lifecycle:case_receive(), closes = closes:case_receive(),
            states = states:case_receive(), loads = loads:case_receive(), activations = activations:case_receive(),
            opens = opens:case_receive(), progress = progress:case_receive()}
        if ticker then cases.ticks = ticker:channel():case_receive() end
        if setup_response then cases.setup = setup_response:case_receive() end
        local event = channel.select(cases)
        if not event.ok then return finish(nil, nil) end
        local refresh = false
        local edit, duplicate = false, false
        local open, attach = false, false
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then return finish(nil, nil) end
        elseif event.channel == closes then
            local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
            if close then client.close_reply(launch, close.request_id, {action = "accept"}); return finish(nil, nil) end
        elseif event.channel == states then
            if event.value:from() == launch.broker_pid then
                local payload: unknown = event.value:payload():data()
                local decoded = appearance.decode(payload)
                if decoded and type(payload) == "table" and payload.version == 1 then preferences = decoded; dirty = true end
            end
        elseif event.channel == loads then
            local result = event.value :: {serial: integer, listing: agents.Listing?, error: string?}
            if result.serial == load_serial then
                loading = false
                listed = no_agents()
                if result.listing then listed = result.listing end
                selected = #listed.items > 0 and 1 or 0
                status = result.error or listed.notes[1] or ""
                dirty = true
                if reload_pending then reload_pending = false; load() end
            end
        elseif event.channel == opens then
            local result = event.value :: Opened
            if result.serial == open_serial then
                opening = false
                if result.conversation then
                    open_target = ""
                    conversation, draft, status, close_key, session_busy = result.conversation, "", "", nil, false
                    ticks = 0
                    ticker = time.ticker("1s")
                    client.title(launch, result.conversation.title)
                else
                    status = result.error or "Agent session did not open"
                end
                dirty = true
            end
        elseif event.channel == progress then
            local result = event.value :: Progress
            if result.conversation == conversation then session_busy = false; dirty = true end
        elseif ticker and event.channel == ticker:channel() then
            local shown = conversation
            ticks = ticks + 1
            if shown and not session_busy and (agents.pending(shown) or shown.activity ~= "idle" or ticks % 5 == 0) then
                start_task(function(current: agents.Conversation) agents.refresh(current) end)
            end
        elseif event.channel == activations then
            local result = event.value :: Activation
            if result.serial == activation_serial then
                activating = false
                if result.admitted then
                    if result.title then client.title(launch, result.title) end
                    return finish(result.admitted, nil)
                end
                if result.error then
                    status = result.error
                else
                    local denied = result.refused and result.refused.error
                    if denied and denied.code == "CONFLICT" then
                        status = "Profile changed. Refresh and select it again."
                        listed = no_agents(); selected = 0
                    else
                        status = denied and (denied.code .. ": " .. denied.message) or "Agent launch was not admitted"
                    end
                end
                dirty = true
            end
        elseif setup_response and event.channel == setup_response then
            local future, request = setup_future, setup_request
            setup_future, setup_response, setup_request = nil, nil, nil
            if future and request then
                local result, setup_error = future:result()
                local setup: unknown = nil
                if result then setup = result:data() end
                local prepared = bounds.object(setup)
                if setup_error or not prepared or prepared.ok ~= true then
                    activations:send({serial = request.serial, error = setup_error and tostring(setup_error) or
                        (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")})
                elseif running and request.serial == activation_serial then
                    coroutine.spawn(function()
                        local choice = request.choice
                        -- A saved profile's folder was associated by setup under
                        -- the name setup returned; its thread replaces this window's.
                        local workdir: string? = nil
                        if choice.workdir then workdir = bounds.id(prepared.workdir) end
                        local admitted, refused = admission.admit_request({request_id = request.request_id,
                            definition_ref = choice.definition_ref, saved_profile_id = choice.saved_profile_id,
                            saved_profile_revision = choice.saved_profile_revision, expected_plan_digest = choice.plan_digest,
                            workspace_id = launch.workspace_id, thread_id = choice.thread_id or launch.thread_id, workdir = workdir,
                            brief = "", mode = "window",
                            origin_view = {view_id = launch.view_id, instance_id = launch.instance_id}})
                        activations:send({serial = request.serial, admitted = admitted, refused = refused, title = choice.title})
                    end)
                end
            end
        else
            local data = input_event.decode(event.value)
            if data then
                if data.type == "close" then return finish(nil, nil)
                elseif data.type == "start" or data.type == "resize" then
                    width, height = data.width, data.height; dirty = true
                elseif editing then
                    local action = profile_view.input(editing, data, edit_frame)
                    if action == "cancel" then editing = nil
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
                        leave_session()
                    elseif data.type == "key" and data.action == "press" and data.key_type == "enter" then submit()
                    elseif data.type == "key" and data.action == "press" and data.ctrl and data.key == "x" then close_session()
                    elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                        local hit = frame.hit(session_frame.hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                        local kind = hit and hit.kind or ""
                        if kind == "back" then leave_session()
                        elseif kind == "send" then submit()
                        elseif kind == "close_session" then close_session() end
                    else
                        local next_draft = session_view.edit(draft, data)
                        if next_draft ~= draft then draft = next_draft; dirty = true end
                    end
                elseif data.type == "key" and data.action == "press" then
                    if data.key_type == "escape" or data.key_type == "esc" then return finish(nil, nil)
                    elseif data.key_type == "up" and selected > 0 and idle() then selected = math.floor(math.max(1, selected - 1)); dirty = true
                    elseif data.key_type == "down" and selected > 0 and idle() then selected = math.floor(math.min(#listed.items, selected + 1)); dirty = true
                    elseif data.key_type == "enter" and idle() then open = true
                    elseif data.ctrl or data.alt then
                    elseif data.key == "m" and idle() then attach = true
                    elseif data.key == "u" and idle() then show_unavailable = not show_unavailable; refresh = true
                    elseif data.key == "r" and idle() then refresh = true
                    elseif data.key == "e" and idle() then edit = true
                    elseif data.key == "n" and idle() then edit = true; duplicate = true end
                elseif data.type == "mouse" then
                    if data.action == "wheel" then
                        if selected > 0 and idle() then
                            local delta = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                            selected = math.floor(math.max(1, math.min(#listed.items, selected + delta))); dirty = true
                        end
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(drawn.hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                        local kind = hit and hit.kind or ""
                        if kind == "close" then return finish(nil, nil)
                        elseif kind == "open" then open = true
                        elseif kind == "attach" then attach = true
                        elseif kind == "unavailable" and idle() then show_unavailable = not show_unavailable; refresh = true
                        elseif kind == "refresh" then refresh = true
                        elseif kind == "edit" then edit = true
                        elseif kind == "new" then edit = true; duplicate = true
                        elseif hit and kind == "choice" and idle() and listed.items[hit.index] then
                            selected = hit.index; dirty = true
                        end
                    end
                end
            end
        end
        if edit and not conversation then
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
        if open and not conversation and not loading and idle() and drawn.capacity > 0 then
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
                            if running and serial == open_serial then opens:send({serial = serial, error = saved_error}) end
                            return
                        end
                        definition, profile = saved.definition_ref, {id = entry.ref, revision = revision}
                    end
                    local opened, open_error = agents.open(sessions.client(), definition, profile, key)
                    if running and serial == open_serial then opens:send({serial = serial, conversation = opened, error = open_error}) end
                end)
            end
        end
        if attach and not conversation and not loading and idle() and drawn.capacity > 0 then
            local entry = listed.items[selected]
            local choice: Choice? = nil
            if entry and entry.ready then
                local definition_ref, title = entry.ref, entry.title
                local saved_id: string? = nil
                local saved_revision: integer? = nil
                local workdir: {root_ref: string, path: string}? = nil
                local thread_id: string? = nil
                local resolve_error: string? = nil
                if entry.kind == "profile" then
                    local revision = entry.revision or 0
                    local saved, saved_error = forms.saved(launch.workspace_id, entry.ref, revision)
                    if saved then
                        definition_ref, title, saved_id, saved_revision = saved.definition_ref, saved.title, entry.ref, revision
                        workdir, thread_id = saved.workdir, saved.thread and saved.thread.thread_id
                    else
                        resolve_error = saved_error
                    end
                end
                if not resolve_error then
                    local plan, refused = admission.resolve(definition_ref, "window", launch.workspace_id, saved_id, saved_revision)
                    if plan then
                        choice = {definition_ref = definition_ref, title = title, plan_digest = plan.plan_digest,
                            saved_profile_id = saved_id, saved_profile_revision = saved_revision, workdir = workdir, thread_id = thread_id}
                    else
                        resolve_error = fault(refused)
                    end
                end
                if resolve_error then status = resolve_error; dirty = true end
            end
            if choice then
                if not request_id or request_definition ~= choice.definition_ref or request_plan ~= choice.plan_digest then
                    request_id = assert(uuid.v7())
                    request_definition, request_plan = choice.definition_ref, choice.plan_digest
                end
                activation_serial = activation_serial + 1
                local serial = activation_serial
                local id = request_id :: string
                activating = true
                status = "Starting Agent…"
                dirty = true
                local future, future_error = funcs.async("bee.harness.launch:setup", {
                    workspace_id = launch.workspace_id, definition_ref = choice.definition_ref,
                    saved_profile_id = choice.saved_profile_id, saved_profile_revision = choice.saved_profile_revision,
                    expected_plan_digest = choice.plan_digest, workdir = choice.workdir})
                if not future then
                    activations:send({serial = serial, error = tostring(future_error)})
                else
                    local response = future:response() :: Channel<unknown>
                    if not response then
                        future:cancel()
                        activations:send({serial = serial, error = "Agent resource setup did not return a response"})
                    else
                        setup_future, setup_response = future, response
                        setup_request = {serial = serial, request_id = id, choice = choice}
                    end
                end
            end
        end
        if refresh then
            load()
        end
    end
end
return M
