-- MIT. Physical status acceptance through a host-admitted thread association.
-- The saved client target contains only the host reply's view identity. The
-- thread ID reaches the session solely from the fresh host inventory.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local funcs = require("funcs")
local uuid = require("uuid")
local logger = require("logger")
local desktops = require("desktops")
local store = require("store")
local state = require("state")
local model = require("model")
local decode = require("decode")
local launch_protocol = require("launch_protocol")
local log = logger:named("bee.thread_status_probe")

local ACTOR = "bee.desktop_client_probe:status_viewer"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end

local function wait_text(view: tty.Viewport, text: string)
    for _ = 1, 500 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows, "\n"):find(text, 1, true) then return end
        time.sleep("10ms")
    end
    local frame = view:snapshot()
    error("Missing bound-thread status: " .. text .. "\n" .. (frame and table.concat(frame.rows, "\n") or "No frame"))
end

local function command(view: tty.Viewport, text: string)
    assert(view:send({type = "paste", text = text}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
end

local function wait_frame(view: tty.Viewport, first: string, second: string, third: string?)
    for _ = 1, 500 do
        local frame = view:snapshot()
        local text = frame and table.concat(frame.rows, "\n") or ""
        if text:find(first, 1, true) and text:find(second, 1, true)
            and (third == nil or text:find(third, 1, true)) then return end
        time.sleep("10ms")
    end
    local frame = view:snapshot()
    error("Missing retained frame: " .. first .. " / " .. second .. (third and " / " .. third or "") .. "\n"
        .. (frame and table.concat(frame.rows, "\n") or "No frame"))
end

local function main()
    local owner = tostring(process.pid())
    local hosts = assert(process.listen("bee.host.ready", {message = true}))
    local clients = assert(process.listen("bee.client.ready", {message = true}))
    local renderers = assert(process.listen("bee.client.renderer", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local events = assert(process.events())
    local function wait_exit(pid: string, phase: string, expected_termination: boolean?)
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({events:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Timed out waiting for " .. phase) end
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == pid then
                local event_result: unknown = event.result
                if type(event_result) == "table" and event_result.error ~= nil and not expected_termination then
                    error(phase .. " failed: " .. tostring(event_result.error))
                end
                return
            end
        end
    end
    local host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = owner}):with_scope(scope({
        "bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"})):spawn_monitored(
            "bee.host:main", "bee:workers", owner)))
    local host_ready = assert(hosts:receive())
    assert(tostring(host_ready:from()) == host)
    local ready: unknown = host_ready:payload():data()
    if type(ready) ~= "table" or type(ready.workspace_id) ~= "string" then error("Invalid host readiness") end
    local workspace_id = ready.workspace_id

    local function host_reply(request_id: string, op: string): decode.Reply
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Missing host reply: " .. request_id) end
            local message = selected.value
            if tostring(message:from()) == host then
                local reply = decode.reply(message:payload():data())
                if reply and reply.request_id == request_id and reply.op == op then return reply end
            end
        end
        error("Unreachable in host_reply")
    end
    local function result(request_id: string)
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({results:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Missing host client result: " .. request_id) end
            local message = selected.value
            if tostring(message:from()) == host then
                local value: unknown = message:payload():data()
                if type(value) == "table" and value.request_id == request_id then
                    assert(value.error_code == "", "Host rejected " .. request_id .. ": " .. tostring(value.error))
                    return
                end
            end
        end
    end
    local thread_scope = scope({"bee.desktop_client_probe:root_policy"})
    local thread_actor = security.new_actor(ACTOR)
    local function thread_call(target: string, request: unknown): {[string]: unknown}
        local reply, err = funcs.new():with_actor(thread_actor):with_scope(thread_scope):call(target, request)
        if err or type(reply) ~= "table" then error("Thread call failed: " .. tostring(err)) end
        local result = reply :: {[string]: unknown}
        if result.ok ~= true then
            local failure: unknown = result.error
            error("Thread owner rejected call: " .. tostring(failure and (failure :: {[string]: unknown}).code))
        end
        return result
    end
    local thread_id = "desktop-status-" .. assert(uuid.v4())
    thread_call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = assert(uuid.v4()), title = "Desktop status"})
    -- A real owner record makes the same actor visibly wait. The session derives
    -- this from its own membership; no status envelope is ever sent by the test.
    local waiting = thread_call("bee.threads.service:record", {thread_id = thread_id, idempotency_key = assert(uuid.v4()), kind = "message",
        body = {message_id = "desktop-wait", message_kind = "request", recipient_ids = {ACTOR}, content = {text = "Please review"}}})
    local waiting_value: unknown = waiting.value
    if type(waiting_value) ~= "table" or type(waiting_value.record_id) ~= "string" then error("Thread record did not return its identity") end
    local waiting_record_id = waiting_value.record_id

    assert(process.send(host, "bee.app.request", {version = 1, request_id = "thread-bound-open", op = "open",
        workspace_id = workspace_id, definition_id = "bee.console:app", thread_id = thread_id,
        arguments = {"bash", "--noprofile", "--norc", "-i"}}))
    local opened = host_reply("thread-bound-open", "open")
    assert(opened.error_code == "" and opened.thread_id == thread_id and opened.id ~= "" and opened.instance_id ~= "",
        "Host did not retain the thread-authorized application association")

    -- This is the same durable target recovery uses. It deliberately contains
    -- no thread metadata; the client intersects it with host inventory before
    -- sending the authenticated complete binding snapshot to its session.
    local database = assert(store.open("bee.client.db:status"))
    -- Leave room for the full test-only renderer marker beside friendly labels.
    local saved = state.empty(120, 32)
    saved.scene = model.add(saved.scene, opened.id, opened.instance_id, opened.title, opened.icon, workspace_id)
    saved.tabs = {opened.id}
    saved.targets = {{tab_id = opened.id, workspace_id = workspace_id, view_id = opened.id, instance_id = opened.instance_id}}
    assert(store.write(database, saved))
    assert(store.close(database))

    local retained = desktops.new()
    local function wait_client_exit(pid: string, phase: string, expected_termination: boolean?)
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({events:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Timed out waiting for " .. phase) end
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == pid then
                local event_result: unknown = event.result
                if type(event_result) == "table" and event_result.error ~= nil and not expected_termination then
                    error(phase .. " failed: " .. tostring(event_result.error))
                end
                assert(desktops.exited(retained, event), "Desktop did not release its local ownership")
                return
            end
        end
    end
    local function start(): (string, tty.Viewport)
        local selected: desktops.Selection = {host = host, workspace_id = workspace_id, database = "bee.client.db:status",
            width = 120, height = 32, application = nil,
            options = {version = 1, quit_mode = "detach", arguments = {}}}
        local desktop, start_error = desktops.start(retained, selected, scope({"bee:desktop_policy", "bee:client_spawn_policy",
            "bee.desktop_client_probe:status_policy"}))
        if not desktop then error(tostring(start_error)) end
        local client = desktop.pid
        local ready_message = assert(clients:receive())
        assert(tostring(ready_message:from()) == client)
        local ready = launch_protocol.ready(ready_message:payload():data(), workspace_id, false)
        if not ready then error("Invalid client readiness") end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = "status-admit", op = "admit",
            workspace_id = workspace_id, recipient = client, display_id = ready.client_id,
            permissions = {open = true, close = true, control = true, appearance = false}}))
        result("status-admit")
        local renderer_message = assert(renderers:receive())
        assert(tostring(renderer_message:from()) == client)
        local renderer: unknown = renderer_message:payload():data()
        if type(renderer) ~= "table" or type(renderer.renderer) ~= "string" then error("Invalid renderer") end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = "status-render", op = "render",
            workspace_id = workspace_id, recipient = client, renderer = renderer.renderer}))
        result("status-render")
        return client, desktop.view
    end
    local client, screen = start()
    wait_text(screen, "bash-")
    wait_text(screen, "Waiting on you")
    command(screen, "bee_thread_session=retained; printf 'THREAD_OWNER_%s\\n' \"$bee_thread_session\"")
    wait_frame(screen, "THREAD_OWNER_retained", "Waiting on you")

    assert(screen:send({type = "key", key = "f12", key_type = "f12", action = "press"}))
    local rejoin = assert(renderers:receive())
    assert(tostring(rejoin:from()) == client)
    local replacement: unknown = rejoin:payload():data()
    if type(replacement) ~= "table" or type(replacement.renderer) ~= "string" then error("Invalid replacement renderer") end
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "status-f12", op = "render",
        workspace_id = workspace_id, recipient = client, renderer = replacement.renderer}))
    result("status-f12")
    -- The test-only presenter header marker identifies the renderer that now
    -- owns this physical view. Wait for its retained shell frame and the
    -- owner-derived badge before input; host admission alone precedes attach.
    wait_frame(screen, replacement.renderer:sub(-12), "THREAD_OWNER_retained", "Waiting on you")
    -- Send once only after the replacement renderer attached.
    command(screen, "test \"$bee_thread_session\" = retained && printf 'THREAD_%s_RETAINED\\n' F12")
    wait_frame(screen, "THREAD_F12_RETAINED", "Waiting on you")

    assert(screen:send({type = "key", key = "q", key_type = "runes", ctrl = true, action = "press"}))
    wait_client_exit(client, "bound client detach")
    screen:close()
    client, screen = start()
    wait_text(screen, "bash-")
    command(screen, "test \"$bee_thread_session\" = retained && printf 'THREAD_%s_RETAINED\\n' RECONNECT")
    wait_frame(screen, "THREAD_RECONNECT_RETAINED", "Waiting on you")
    local recovered = assert(store.open("bee.client.db:status"))
    local recovered_state = assert(store.read(recovered))
    assert(#recovered_state.targets == 1 and recovered_state.targets[1].view_id == opened.id
        and recovered_state.targets[1].instance_id == opened.instance_id, "Client reconnect did not retain the host-bound view")
    assert(store.close(recovered))

    -- This is a new committed owner record, not a replayed presenter frame. The
    -- fresh session must consume it through the original authenticated binding.
    thread_call("bee.threads.service:record", {thread_id = thread_id, idempotency_key = assert(uuid.v4()), kind = "message",
        body = {message_id = "desktop-reply", message_kind = "reply", recipient_ids = {}, content = {text = "Reviewed"},
            in_reply_to = {thread_id = thread_id, record_id = waiting_record_id}, outcome = "succeeded"}})
    command(screen, "printf 'THREAD_%s_STATUS_UPDATED\\n' REPLY")
    wait_frame(screen, "THREAD_REPLY_STATUS_UPDATED", "Idle")

    assert(process.terminate(client))
    wait_client_exit(client, "bound client cleanup", true)
    screen:close()
    assert(process.terminate(host))
    wait_exit(host, "host cleanup", true)
    process.unlisten(hosts); process.unlisten(clients); process.unlisten(renderers); process.unlisten(results); process.unlisten(replies)
    log:info("THREAD_STATUS_PROBE_COMPLETE")
end
local function checked_main()
    local ok, failure = pcall(main)
    if not ok then
        log:error("THREAD_STATUS_PROBE_FAILURE", {error = tostring(failure)})
        error(failure)
    end
end

return {main = checked_main}
