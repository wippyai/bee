-- MIT. Two actual desktop owners render into separate native terminal grants.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
type Channel = channel.Channel
local store = require("store")
local decode = require("decode")
local interaction = require("interaction")
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    return security.new_scope(policies)
end
local function wait_text(view: tty.Viewport, text: string)
    for _ = 1, 500 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows, "\n"):find(text, 1, true) then return end
        time.sleep("10ms")
    end
    local last = view:snapshot()
    error("Missing desktop output: " .. text .. "\n" .. (last and table.concat(last.rows, "\n") or "No frame"))
end
local function command(view: tty.Viewport, value: string)
    assert(view:send({type = "paste", text = value}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
end
local function key(view: tty.Viewport, value: string, ctrl: boolean?)
    assert(view:send({type = "key", key = value, key_type = #value == 1 and "runes" or value,
        ctrl = ctrl or false, action = "press"}))
end
local function click_text(view: tty.Viewport, text: string)
    local frame = assert(view:snapshot())
    for y, row in ipairs(frame.rows) do
        local plain = row:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
        local index = plain:find(text, 1, true)
        if index then
            local x = tty.text.width(plain:sub(1, index - 1)) + 1
            assert(view:send({type = "mouse", button = "left", action = "press", x = x, y = y}))
            assert(view:send({type = "mouse", button = "left", action = "release", x = x, y = y}))
            return
        end
    end
    error("Missing click target: " .. text)
end
local function wait_absent(view: tty.Viewport, text: string, phase: string, events: Channel<process.Event>)
    for _ = 1, 500 do
        local frame = view:snapshot()
        if frame and not table.concat(frame.rows, "\n"):find(text, 1, true) then return end
        local selected = channel.select({events:case_receive(), time.after("10ms"):case_receive()})
        if selected.channel == events and selected.ok then
            local event = selected.value
            if event.kind == process.event.EXIT then error("Desktop owner exited during " .. phase .. ": " .. tostring(event.error)) end
        end
    end
    local last = view:snapshot()
    error("Desktop retained question after " .. phase .. ": " .. text .. "\n" .. (last and table.concat(last.rows, "\n") or "No frame"))
end
local function main()
    local owner = tostring(process.pid())
    local hosts = assert(process.listen("bee.host.ready", {message = true}))
    local clients = assert(process.listen("bee.client.ready", {message = true}))
    local renderers = assert(process.listen("bee.client.renderer", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local quit_requests = assert(process.listen("bee.client.quit", {message = true}))
    local shutdown_answers = assert(process.listen("bee.client.shutdown_answer", {message = true}))
    local stopped_clients = assert(process.listen("bee.client.exit_ready", {message = true}))
    local saved_clients = assert(process.listen("bee.client.saved", {message = true}))
    local host_questions = assert(process.listen("bee.interaction.state", {message = true}))
    local events, event_error = process.events()
    if not events then error(tostring(event_error)) end
    local host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = owner}):with_scope(scope({
        "bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"})):spawn_monitored("bee.host:main", "bee:workers", owner)))
    local host_ready = assert(hosts:receive())
    assert(tostring(host_ready:from()) == host)
    local data: unknown = host_ready:payload():data()
    if type(data) ~= "table" or type(data.workspace_id) ~= "string" then error("Invalid host readiness") end
    local workspace_id = data.workspace_id
    local host_saved: unknown = data.saved
    if type(host_saved) ~= "table" or type(host_saved.desktop) ~= "table" then error("Missing legacy desktop offer") end
    local legacy_desktop: unknown = host_saved.desktop
    local imported_receipt = ""
    local function host_reply(request_id: string, op: string): decode.Reply
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Missing host reply: " .. op .. "/" .. request_id) end
            local message = selected.value
            assert(tostring(message:from()) == host)
            local reply = decode.reply(message:payload():data())
            if not reply then error("Invalid host reply") end
            if reply.request_id == request_id and reply.op == op then return reply end
        end
        error("Host reply channel closed")
    end
    local function result(request_id: string)
        while true do
            local message = assert(results:receive())
            assert(tostring(message:from()) == host)
            local value: unknown = message:payload():data()
            if type(value) == "table" and value.request_id == request_id then
                assert(value.error_code == "", "Host rejected client setup")
                return
            end
        end
    end
    local function start(label: string, width: integer, launch: boolean): (string, tty.Viewport)
        local screen, err = tty.viewport({width = width, height = 32})
        if not screen then error(tostring(err)) end
        local grant = assert(screen:grant())
        local client = tostring(assert(process.with_options({terminal = grant}):with_context({["bee.client_owner"] = owner}):with_scope(scope({
            "bee:desktop_policy", "bee:client_spawn_policy", "bee.desktop_client_probe:" .. label .. "_policy"})):spawn_monitored(
                "bee.client:main", "bee:workers", owner, host, workspace_id, "bee.client.db:" .. label,
                launch and "bee.console:app" or nil, {version = 1, quit_mode = label == "right" and "supervisor" or "detach",
                    fullscreen = label == "left",
                    arguments = label == "left" and {"env", "BEE_LAUNCH_LITERAL=space ; $HOME", "bash", "--noprofile", "--norc", "-i"} or nil,
                    legacy_desktop = label == "left" and legacy_desktop or nil})))
        local ready = assert(clients:receive())
        assert(tostring(ready:from()) == client)
        local ready_data: unknown = ready:payload():data()
        if type(ready_data) ~= "table" or type(ready_data.import_receipt) ~= "string" then error("Missing import result") end
        if label == "left" then
            assert(#ready_data.import_receipt == 32, "Import was not committed before readiness")
            if imported_receipt ~= "" then assert(ready_data.import_receipt == imported_receipt, "Import retry changed its receipt") end
            imported_receipt = ready_data.import_receipt
        else
            assert(ready_data.import_receipt == "", "Client without legacy offer imported state")
        end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = label .. "-admit", op = "admit",
            workspace_id = workspace_id, recipient = client, permissions = {open = true, close = true, control = true, appearance = label == "left"}}))
        result(label .. "-admit")
        local selected = assert(renderers:receive())
        assert(tostring(selected:from()) == client)
        local value: unknown = selected:payload():data()
        if type(value) ~= "table" or type(value.renderer) ~= "string" or value.workspace_id ~= workspace_id then error("Invalid renderer selection") end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = label .. "-render", op = "render",
            workspace_id = workspace_id, recipient = client, renderer = value.renderer}))
        result(label .. "-render")
        wait_text(screen, label == "left" and "bash-" or "Terminal")
        if launch then
            command(screen, "bee_desktop=" .. label .. "; printf 'DESKTOP_%s_OK\\n' \"$bee_desktop\"")
            wait_text(screen, "DESKTOP_" .. label .. "_OK")
            if label == "left" then
                command(screen, "printf 'ARG_%s_END\\n' \"$BEE_LAUNCH_LITERAL\"")
                wait_text(screen, "ARG_space ; $HOME_END")
            end
        else
            command(screen, "printf 'RESUMED_%s_OK\\n' \"$bee_desktop\"")
            wait_text(screen, "RESUMED_" .. label .. "_OK")
        end
        return client, screen
    end
    local left, left_screen = start("left", 100, true)
    local right, right_screen = start("right", 120, true)
    local probe_store, probe_error = store.open("bee.client.db:left")
    if not probe_store then error(tostring(probe_error)) end
    local probe_state = store.read(probe_store)
    if not probe_state or not probe_state.targets[1] then error("Missing close target") end
    local close_target = probe_state.targets[1]
    assert(probe_state.scene.windows[1].mode == "fullscreen", "Initial fullscreen option was not applied")
    assert(store.close(probe_store))
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "stale-close", op = "close",
        workspace_id = workspace_id, id = close_target.view_id, instance_id = "another-instance"}))
    assert(host_reply("stale-close", "close").error_code == "stale_instance", "Close did not enforce the target instance")
    command(left_screen, "printf 'STILL_%s_HERE\\n' \"$bee_desktop\"")
    wait_text(left_screen, "STILL_left_HERE")
    key(left_screen, "w", true)
    wait_text(left_screen, "Close terminal?")
    local other_frame = assert(right_screen:snapshot())
    assert(not table.concat(other_frame.rows, "\n"):find("Close terminal?", 1, true), "Question leaked into an unrelated client")
    command(right_screen, "printf 'DIALOG_%s_INDEPENDENT\\n' \"$bee_desktop\"")
    wait_text(right_screen, "DIALOG_right_INDEPENDENT")
    assert(left_screen:send({type = "key", key = "f12", key_type = "f12", action = "press"}))
    local replacement = assert(renderers:receive())
    assert(tostring(replacement:from()) == left)
    local replacement_data: unknown = replacement:payload():data()
    if type(replacement_data) ~= "table" or type(replacement_data.renderer) ~= "string" then error("Missing replacement renderer") end
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "left-rejoin", op = "render",
        workspace_id = workspace_id, recipient = left, renderer = replacement_data.renderer}))
    result("left-rejoin")
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "left-rejoin-repeat", op = "render",
        workspace_id = workspace_id, recipient = left, renderer = replacement_data.renderer}))
    result("left-rejoin-repeat")
    -- Rehydration must publish the old native content before input resumes.
    wait_text(left_screen, "STILL_left_HERE")
    time.sleep("100ms")
    wait_text(left_screen, "Close terminal?")
    key(left_screen, "escape")
    wait_absent(left_screen, "Close terminal?", "cancel", events)
    command(left_screen, "printf 'REJOINED_%s_OK\\n' \"$bee_desktop\"")
    wait_text(left_screen, "REJOINED_left_OK")
    for _, label in ipairs({"left", "right"}) do
        local database, err = store.open("bee.client.db:" .. label)
        if not database then error(tostring(err)) end
        local saved, read_error = store.read(database)
        if not saved then error(tostring(read_error)) end
        assert(#saved.targets == 1, "Client selected another desktop's app")
        assert(saved.targets[1].workspace_id == workspace_id and saved.targets[1].tab_id ~= saved.targets[1].view_id)
        assert(saved.scene.width == (label == "left" and 100 or 120), "Client layouts share geometry")
        assert(store.close(database))
    end
    -- No frame wait: the final session snapshot must include this accepted
    -- resize even if its ordinary scene notification has not been consumed.
    assert(left_screen:resize(111, 35))
    assert(left_screen:send({type = "key", key = "q", key_type = "runes", ctrl = true, action = "press"}))
    while true do
        local event = assert(events:receive())
        if event.kind == process.event.EXIT and tostring(event.from) == left then break end
    end
    command(right_screen, "printf 'SURVIVED_%s_EXIT\\n' \"$bee_desktop\"")
    wait_text(right_screen, "SURVIVED_right_EXIT")
    local database, database_error = store.open("bee.client.db:left")
    if not database then error(tostring(database_error)) end
    local saved, saved_error = store.read(database)
    if not saved then error(tostring(saved_error)) end
    assert(saved.scene.width == 111 and saved.scene.height == 35, "Immediate exit lost the accepted resize")
    local target = saved.targets[1]
    if not target then error("Client exit lost its selected target") end
    assert(store.close(database))
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "retained", op = "bind",
        workspace_id = workspace_id, id = target.view_id, instance_id = target.instance_id, recipient = owner}))
    local mounted = host_reply("retained", "attached")
    assert(mounted.error_code == "", "Retained Terminal did not attach")
    local retained, attach_error = tty.attach(mounted.mount)
    if not retained then error(tostring(attach_error)) end
    command(retained, "printf 'RETAINED_%s_PROCESS\\n' \"$bee_desktop\"")
    wait_text(retained, "RETAINED_left_PROCESS")
    retained:close()
    -- A fresh client execution imports no host checkpoint and selects no new app.
    local resumed, resumed_screen = start("left", 100, false)
    key(resumed_screen, "w", true)
    wait_text(resumed_screen, "Close terminal?")
    key(resumed_screen, "tab")
    key(resumed_screen, "enter")
    wait_absent(resumed_screen, "Close terminal?", "accept", events)
    local closed = false
    local final_store, final_error = store.open("bee.client.db:left")
    if not final_store then error(tostring(final_error)) end
    for _ = 1, 500 do
        local final_state = store.read(final_store)
        if final_state and #final_state.targets == 0 then closed = true; break end
        time.sleep("10ms")
    end
    assert(store.close(final_store))
    assert(closed, "Confirmed close did not retire the selected target")
    local appearance_store = store.open("bee.client.db:left")
    if not appearance_store then error("Cannot open client appearance store") end
    local before = assert(store.read(appearance_store))
    local other_store = store.open("bee.client.db:right")
    if not other_store then error("Cannot open other client store") end
    local other_before = assert(store.read(other_store))
    key(resumed_screen, "f1")
    wait_text(resumed_screen, "Tools")
    click_text(resumed_screen, "Tools")
    wait_text(resumed_screen, "Settings")
    click_text(resumed_screen, "Settings")
    wait_text(resumed_screen, "BEE SETTINGS")
    key(resumed_screen, "end")
    local updated = false
    for _ = 1, 500 do
        local saved = store.read(appearance_store)
        if saved and saved.preferences.theme ~= before.preferences.theme then updated = true; break end
        time.sleep("10ms")
    end
    assert(updated, "Settings did not persist the client theme")
    local themed = store.read(appearance_store)
    if not themed then error("Missing themed client state") end
    key(resumed_screen, "f12")
    local settings_renderer = assert(renderers:receive())
    assert(tostring(settings_renderer:from()) == resumed)
    local settings_renderer_data: unknown = settings_renderer:payload():data()
    if type(settings_renderer_data) ~= "table" or type(settings_renderer_data.renderer) ~= "string" then error("Missing Settings renderer") end
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "settings-rejoin", op = "render",
        workspace_id = workspace_id, recipient = resumed, renderer = settings_renderer_data.renderer}))
    result("settings-rejoin")
    wait_text(resumed_screen, "BEE SETTINGS")
    -- Require a committed change after rejoin, not just the retained old frame.
    for _ = 1, 100 do
        key(resumed_screen, "home")
        local saved = store.read(appearance_store)
        if saved and saved.preferences.theme ~= themed.preferences.theme then break end
        time.sleep("20ms")
    end
    local rejoined_state = store.read(appearance_store)
    assert(rejoined_state and rejoined_state.preferences.theme ~= themed.preferences.theme, "Settings lost its route after F12")
    local other_after = assert(store.read(other_store))
    assert(other_after.preferences.theme == other_before.preferences.theme, "Settings recolored another client")
    key(resumed_screen, "escape")
    wait_absent(resumed_screen, "BEE SETTINGS", "Settings close", events)
    key(right_screen, "f1")
    wait_text(right_screen, "Tools")
    click_text(right_screen, "Tools")
    wait_text(right_screen, "Settings")
    click_text(right_screen, "Settings")
    wait_text(right_screen, "BEE SETTINGS")
    key(right_screen, "end")
    wait_text(right_screen, "not granted")
    local denied_state = store.read(other_store)
    assert(denied_state and denied_state.preferences.theme == other_before.preferences.theme,
        "Client without appearance permission changed its theme")
    local function prepare_shutdown(): interaction.Spec
        assert(process.send(host, "bee.application.shutdown", {version = 1, op = "prepare"}))
        while true do
            local message = assert(host_questions:receive())
            assert(tostring(message:from()) == host)
            local question = interaction.shutdown(message:payload():data())
            if question then
                assert(process.send(right, "bee.client.control", {version = 1, workspace_id = workspace_id,
                    request_id = question.request_id, op = "state", shutdown = interaction.wire(question)}))
                wait_text(right_screen, question.title)
                return question
            end
        end
        error("Host question channel closed")
    end
    key(right_screen, "q", true)
    local quit_message = assert(quit_requests:receive())
    assert(tostring(quit_message:from()) == right)
    local first_question = prepare_shutdown()
    key(right_screen, "escape")
    local answer_message = assert(shutdown_answers:receive())
    assert(tostring(answer_message:from()) == right)
    local answer_data: unknown = answer_message:payload():data()
    assert(type(answer_data) == "table" and answer_data.request_id == first_question.request_id and answer_data.action == "cancel")
    assert(process.send(host, "bee.interaction.response", answer_data))
    while true do
        local message = assert(host_questions:receive())
        assert(tostring(message:from()) == host)
        local cleared: unknown = message:payload():data()
        if type(cleared) == "table" and cleared.shutdown == nil then break end
    end
    assert(process.send(right, "bee.client.control", {version = 1, workspace_id = workspace_id,
        request_id = "quit-cancelled", op = "state"}))
    wait_absent(right_screen, first_question.title, "supervised quit cancellation", events)
    wait_text(right_screen, "BEE SETTINGS")
    key(right_screen, "q", true)
    assert(tostring(assert(quit_requests:receive()):from()) == right)
    local second_question = prepare_shutdown()
    assert(second_question.request_id ~= first_question.request_id, "Shutdown reused cancelled question")
    key(right_screen, "tab")
    key(right_screen, "enter")
    local accepted_message = assert(shutdown_answers:receive())
    assert(tostring(accepted_message:from()) == right)
    local accepted: unknown = accepted_message:payload():data()
    assert(type(accepted) == "table" and accepted.request_id == second_question.request_id and accepted.action == "accept")
    assert(process.send(host, "bee.interaction.response", accepted))
    assert(host_reply(second_question.request_id, "quit").error_code == "")
    assert(process.send(right, "bee.client.control", {version = 1, workspace_id = workspace_id,
        request_id = "save-before-host", op = "save"}))
    local saved_message = assert(saved_clients:receive())
    assert(tostring(saved_message:from()) == right)
    local saved_data: unknown = saved_message:payload():data()
    assert(type(saved_data) == "table" and saved_data.request_id == "save-before-host")
    local before_cleanup = store.read(other_store)
    if not before_cleanup then error("Missing saved client layout") end
    assert(process.send(host, "bee.app.request", {version = 1, workspace_id = workspace_id,
        request_id = "host-shutdown", op = "shutdown"}))
    assert(host_reply("host-shutdown", "shutdown").error_code == "", "Host did not complete negotiated cleanup")
    assert(process.send(right, "bee.client.control", {version = 1, workspace_id = workspace_id,
        request_id = "save-and-exit", op = "exit"}))
    local stopped_message = assert(stopped_clients:receive())
    assert(tostring(stopped_message:from()) == right)
    local stopped_data: unknown = stopped_message:payload():data()
    assert(type(stopped_data) == "table" and stopped_data.workspace_id == workspace_id and stopped_data.request_id == "save-and-exit")
    local after_cleanup = store.read(other_store)
    assert(after_cleanup and #after_cleanup.targets == #before_cleanup.targets,
        "Host shutdown erased saved client tabs")
    assert(store.close(appearance_store)); assert(store.close(other_store))
    process.terminate(resumed)
    resumed_screen:close()
    process.terminate(right)
    process.terminate(host)
    left_screen:close(); right_screen:close()
end
return {main = main}
