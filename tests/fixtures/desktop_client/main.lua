-- MIT. Two actual desktop owners render into separate native terminal grants.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local logger = require("logger")
local log = logger:named("bee.desktop_client_probe")
type Channel = channel.Channel
local store = require("store")
local desktops = require("desktops")
local desktop_attachments = require("desktop_attachments")
local decode = require("decode")
local launch_protocol = require("launch_protocol")
local interaction = require("interaction")
local names = require("names")
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
local function click_text(view: tty.Viewport, text: string, button: string?)
    local frame = assert(view:snapshot())
    for y, row in ipairs(frame.rows) do
        local plain = row:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
        local index = plain:find(text, 1, true)
        if index then
            local x = tty.text.width(plain:sub(1, index - 1)) + 1
            assert(view:send({type = "mouse", button = button or "left", action = "press", x = x, y = y}))
            assert(view:send({type = "mouse", button = button or "left", action = "release", x = x, y = y}))
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
local function main(mode: string?)
    local shared_store = mode == "shared-store"
    local selected_id = string.rep("b", 32)
    local function open_store(resource: string): (store.Store?, string?)
        if shared_store and resource == "bee.client.db:right" then return store.open("bee.client.db:left", selected_id) end
        return store.open(resource)
    end
    if shared_store then
        local allocator, allocation_error = store.open("bee.client.db:left")
        if not allocator then error(tostring(allocation_error)) end
        assert(store.allocate(allocator, selected_id))
        assert(store.close(allocator))
    end
    local owner = tostring(process.pid())
    local retained_desktops = desktops.new()
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
        local selection: desktops.Selection = {host = host, workspace_id = workspace_id,
            database = "bee.client.db:" .. (shared_store and label == "right" and "left" or label), width = width, height = 32,
            application = launch and "bee.console:app" or nil,
            options = {version = 1, desktop_id = shared_store and label == "right" and selected_id or nil, quit_mode = label == "right" and "supervisor" or "detach",
                fullscreen = label == "left",
                arguments = label == "left" and {"env", "BEE_LAUNCH_LITERAL=space ; $HOME", "bash", "--noprofile", "--norc", "-i"}
                    or {"bash", "--noprofile", "--norc", "-i"},
                legacy_desktop = label == "left" and launch and legacy_desktop or nil}}
        local client_scope = scope({"bee:desktop_policy", "bee:client_spawn_policy",
            "bee.desktop_client_probe:" .. label .. "_policy"})
        local desktop, start_error = desktops.start(retained_desktops, selection, client_scope)
        if not desktop then error(tostring(start_error)) end
        local duplicate, duplicate_error = desktops.start(retained_desktops, selection, client_scope)
        assert(not duplicate and duplicate_error ~= nil, "Duplicate desktop store owner admitted")
        local client, screen = desktop.pid, desktop.view
        local ready = assert(clients:receive())
        assert(tostring(ready:from()) == client)
        local ready_data = launch_protocol.ready(ready:payload():data(), workspace_id, label == "left")
        if not ready_data then error("Invalid desktop readiness or missing required import") end
        if shared_store and label == "right" then assert(ready_data.client_id == selected_id) end
        if label == "left" and launch then
            assert(#ready_data.import_receipt == 32, "Import was not committed before readiness")
            if imported_receipt ~= "" then assert(ready_data.import_receipt == imported_receipt, "Import retry changed its receipt") end
            imported_receipt = ready_data.import_receipt
        else
            assert(ready_data.import_receipt == "", "Client without legacy offer imported state")
        end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = label .. "-admit", op = "admit",
            workspace_id = workspace_id, recipient = client, display_id = ready_data.client_id,
            permissions = {open = label ~= "observer", close = label ~= "observer", control = label ~= "observer", appearance = label == "left"}}))
        result(label .. "-admit")
        local selected = assert(renderers:receive())
        assert(tostring(selected:from()) == client)
        local value: unknown = selected:payload():data()
        if type(value) ~= "table" or type(value.renderer) ~= "string" or value.workspace_id ~= workspace_id then error("Invalid renderer selection") end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = label .. "-render", op = "render",
            workspace_id = workspace_id, recipient = client, renderer = value.renderer}))
        result(label .. "-render")
        -- A title precedes the attachment. Wait for real PTY output before input.
        wait_text(screen, "bash-")
        if launch then
            command(screen, "bee_desktop=" .. label .. "; printf 'DESKTOP_%s_OK\\n' \"$bee_desktop\"")
            wait_text(screen, "DESKTOP_" .. label .. "_OK")
            if label == "left" then
                command(screen, "printf 'ARG_%s_END\\n' \"$BEE_LAUNCH_LITERAL\"")
                wait_text(screen, "ARG_space ; $HOME_END")
            end
        elseif label ~= "observer" then
            command(screen, "printf 'RESUMED_%s_OK\\n' \"$bee_desktop\"")
            wait_text(screen, "RESUMED_" .. label .. "_OK")
        end
        return client, screen
    end
    local left, left_screen = start("left", 100, true)
    local right, right_screen = start("right", 120, true)
    if mode == "transfer" or mode == "transfer-source-save-failure" or mode == "transfer-target-save-failure" then
        local left_store, left_store_error = open_store("bee.client.db:left")
        if not left_store then error(tostring(left_store_error)) end
        local right_store, right_store_error = open_store("bee.client.db:right")
        if not right_store then error(tostring(right_store_error)) end
        local source_layout, source_error = store.read(left_store)
        if not source_layout then error(tostring(source_error)) end
        local neighbor_layout, neighbor_error = store.read(right_store)
        if not neighbor_layout then error(tostring(neighbor_error)) end
        local moved, neighbor = source_layout.targets[1], neighbor_layout.targets[1]
        if not moved or not neighbor then error("Missing initial transfer identities") end
        command(left_screen, "printf 'MOVE_BEFORE_%s_%s_END\\n' \"$bee_desktop\" \"$$\"")
        wait_text(left_screen, "MOVE_BEFORE_left_")
        local before = table.concat(assert(left_screen:snapshot()).rows, "\n")
        local shell_pid = before:match("MOVE_BEFORE_left_(%d+)_END")
        if not shell_pid then error("Missing source shell PID") end
        local function wait_client_exit(pid: string, label: string)
            local deadline = time.after("5s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("Timed out waiting for " .. label .. " client failure") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == pid then
                    assert(desktops.exited(retained_desktops, event), "Failed " .. label .. " client did not release its desktop")
                    return
                end
            end
        end
        local source_failure = mode == "transfer-source-save-failure"
        local target_failure = mode == "transfer-target-save-failure"
        assert(left_screen:send({type = "mouse", button = "right", action = "press", x = 10, y = 5}))
        assert(left_screen:send({type = "mouse", button = "right", action = "release", x = 10, y = 5}))
        wait_text(left_screen, "Send to display")
        click_text(left_screen, "Send to display")
        local destination = names.label(right_store.client_id)
        wait_text(left_screen, destination)
        click_text(left_screen, destination)
        if source_failure then
            wait_client_exit(left, "source")
            left_screen:close()
        elseif target_failure then
            wait_client_exit(right, "target")
            right_screen:close()
        end
        local moved_layout = false
        for _ = 1, 500 do
            local left_state, right_state = store.read(left_store), store.read(right_store)
            local source_present, target_present = false, false
            for _, target in ipairs(left_state and left_state.targets or {}) do
                if target.view_id == moved.view_id and target.instance_id == moved.instance_id then source_present = true end
            end
            for _, target in ipairs(right_state and right_state.targets or {}) do
                if target.view_id == moved.view_id and target.instance_id == moved.instance_id then target_present = true end
            end
            if (source_failure and source_present and target_present)
                or (target_failure and not source_present and not target_present)
                or (not source_failure and not target_failure and not source_present and target_present) then
                moved_layout = true; break
            end
            time.sleep("10ms")
        end
        assert(moved_layout, "Transfer did not reach the expected real client layouts")
        local function focus_right(id: string)
            for _ = 1, 20 do
                local current = store.read(right_store)
                if current and current.scene.focus == id then return end
                assert(right_screen:send({type = "key", key = "tab", key_type = "tab", alt = true, action = "press"}))
                assert(right_screen:send({type = "key", key = "tab", key_type = "tab", alt = true, action = "release"}))
                time.sleep("30ms")
            end
            error("Cannot focus transferred app or its neighbor")
        end
        if not target_failure then
            focus_right(moved.tab_id)
            command(right_screen, "printf 'MOVE_AFTER_%s_%s_END\\n' \"$bee_desktop\" \"$$\"")
            wait_text(right_screen, "MOVE_AFTER_left_" .. shell_pid .. "_END")
            focus_right(neighbor.tab_id)
            command(right_screen, "printf 'MOVE_NEIGHBOR_%s_END\\n' \"$bee_desktop\"")
            wait_text(right_screen, "MOVE_NEIGHBOR_right_END")
        end
        if source_failure then
            left, left_screen = start("left", 100, false)
            local repaired_source = false
            for _ = 1, 500 do
                local repaired = store.read(left_store)
                local present = false
                for _, target in ipairs(repaired and repaired.targets or {}) do
                    if target.view_id == moved.view_id and target.instance_id == moved.instance_id then present = true end
                end
                if not present then repaired_source = true; break end
                time.sleep("10ms")
            end
            assert(repaired_source, "Restarted stale source reclaimed transferred app")
        elseif target_failure then
            right, right_screen = start("right", 120, false)
            local repaired_target = false
            for _ = 1, 500 do
                local repaired = store.read(right_store)
                local present = false
                for _, target in ipairs(repaired and repaired.targets or {}) do
                    if target.view_id == moved.view_id and target.instance_id == moved.instance_id then present = true end
                end
                if present then repaired_target = true; break end
                time.sleep("10ms")
            end
            assert(repaired_target, "Restarted target did not reproject transferred app")
            focus_right(moved.tab_id)
            command(right_screen, "printf 'MOVE_AFTER_%s_%s_END\\n' \"$bee_desktop\" \"$$\"")
            wait_text(right_screen, "MOVE_AFTER_left_" .. shell_pid .. "_END")
            focus_right(neighbor.tab_id)
            command(right_screen, "printf 'MOVE_NEIGHBOR_%s_END\\n' \"$bee_desktop\"")
            wait_text(right_screen, "MOVE_NEIGHBOR_right_END")
        end
        if source_failure or target_failure then
            assert(store.close(left_store)); assert(store.close(right_store))
            process.terminate(left); process.terminate(right)
            local failure_deadline = time.after("3s")
            while next(retained_desktops.desktops) ~= nil do
                local selected = channel.select({events:case_receive(), failure_deadline:case_receive()})
                if not selected.ok or selected.channel == failure_deadline then error("Transfer failure cleanup did not complete") end
                desktops.exited(retained_desktops, selected.value)
            end
            process.terminate(host)
            log:info("DESKTOP_TRANSFER_SAVE_FAILURE_PROBE_COMPLETE", {mode = mode})
            return
        end
        key(left_screen, "f12")
        local rejoined = false
        for _ = 1, 500 do
            local selected = channel.select({renderers:case_receive(), time.after("10ms"):case_receive()})
            if selected.ok and selected.channel == renderers then
                local value: unknown = selected.value:payload():data()
                if type(value) == "table" and type(value.renderer) == "string" and tostring(selected.value:from()) == left then
                    assert(process.send(host, "bee.host.client", {version = 1, request_id = "transfer-rejoin", op = "render",
                        workspace_id = workspace_id, recipient = left, renderer = value.renderer}))
                    result("transfer-rejoin")
                    rejoined = true
                    break
                end
            end
        end
        assert(rejoined, "Source presenter did not rejoin")
        local rejoined_layout, rejoined_error = store.read(left_store)
        if not rejoined_layout then error(tostring(rejoined_error)) end
        assert(#rejoined_layout.targets == 0, "Source rejoin reclaimed transferred app")
        assert(process.send(host, "bee.app.request", {version = 1, workspace_id = workspace_id, request_id = "transfer-shutdown", op = "shutdown"}))
        assert(host_reply("transfer-shutdown", "shutdown").error_code == "")
        assert(store.close(left_store)); assert(store.close(right_store))
        process.terminate(left); process.terminate(right)
        local deadline = time.after("3s")
        while next(retained_desktops.desktops) ~= nil do
            local selected = channel.select({events:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Transfer display cleanup did not complete") end
            desktops.exited(retained_desktops, selected.value)
        end
        process.terminate(host)
        log:info("DESKTOP_TRANSFER_PROBE_COMPLETE")
        return
    end
    -- Physical presentations attach to the retained virtual desktop. Replacing
    -- one must not recreate the desktop actor, its store, presenter or shell.
    local physical_boot = assert(process.listen("physical.boot", {message = true}))
    local physical_ready = assert(process.listen("physical.ready", {message = true}))
    local left_desktop = retained_desktops.desktops["bee.client.db:left"]
    assert(left_desktop)
    local desktop_grants = left_desktop.grants
    local function attach_physical(): (string, tty.Viewport, string)
        local screen, screen_error = tty.viewport({width = 100, height = 32})
        if not screen then error(tostring(screen_error)) end
        local pid = tostring(assert(process.with_options({terminal = assert(screen:grant())})
            :with_scope(scope({"bee:desktop_policy"})):spawn_monitored(
                "bee.desktop_client_probe:physical", "bee:workers", owner)))
        local booted = assert(physical_boot:receive())
        assert(tostring(booted:from()) == pid)
        local attached = desktop_attachments.attach(desktop_grants, pid, "control")
        assert(attached.error_code == "", attached.error)
        local mount = attached.mount
        local competing = desktop_attachments.attach(desktop_grants, right, "control")
        assert(competing.error_code == "busy" and competing.mount == "", "New display stole control")
        local downgraded = desktop_attachments.attach(desktop_grants, pid, "observe")
        assert(downgraded.error_code == "mode_conflict", "Controller silently changed mode")
        local observed = desktop_attachments.attach(desktop_grants, owner, "observe")
        assert(observed.error_code == "", observed.error)
        local observer_view = assert(tty.attach(observed.mount))
        assert(observer_view:snapshot())
        local sent, denied = observer_view:send({type = "paste", text = "FORBIDDEN_DESKTOP_INPUT"})
        assert(not sent and denied ~= nil, "Desktop observer received input authority")
        local promoted = desktop_attachments.attach(desktop_grants, owner, "control")
        assert(promoted.error_code == "mode_conflict", "Observer silently gained control")
        assert(desktop_attachments.detach(desktop_grants, owner).error_code == "")
        local stale, stale_error = observer_view:snapshot()
        assert(not stale and stale_error ~= nil, "Detached desktop observer remained usable")
        observer_view:close()
        assert(process.send(pid, "physical.configure", {mount = mount}))
        local ready = assert(physical_ready:receive())
        assert(tostring(ready:from()) == pid)
        return pid, screen, mount
    end
    local function detach_physical(pid: string, screen: tty.Viewport, graceful: boolean)
        if graceful then assert(screen:send({type = "close"}))
        else assert(process.terminate(pid)) end
        local deadline = time.after("3s")
        while true do
            local selected = channel.select({events:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Physical display did not exit") end
            local event = selected.value
            if event.kind == process.event.EXIT then
                assert(tostring(event.from) == pid, "Desktop or application exited with its physical client")
                assert(not desktops.exited(retained_desktops, event), "Display exit released desktop ownership")
                break
            end
        end
        local detached = desktop_attachments.detach(desktop_grants, pid)
        assert(detached.error_code == "", detached.error)
        screen:close()
    end
    local physical, physical_screen, physical_mount = attach_physical()
    command(physical_screen, "bee_physical=retained; printf 'PHYSICAL_%s_OK\\n' \"$bee_physical\"")
    wait_text(physical_screen, "PHYSICAL_retained_OK")
    detach_physical(physical, physical_screen, false)
    command(left_screen, "printf 'DETACHED_%s_OK\\n' \"$bee_physical\"")
    wait_text(left_screen, "DETACHED_retained_OK")
    physical, physical_screen, physical_mount = attach_physical()
    command(physical_screen, "printf 'REATTACHED_%s_OK\\n' \"$bee_physical\"")
    wait_text(physical_screen, "REATTACHED_retained_OK")
    detach_physical(physical, physical_screen, true)
    physical, physical_screen, physical_mount = attach_physical()
    command(physical_screen, "printf 'CLOSED_%s_OK\\n' \"$bee_physical\"")
    wait_text(physical_screen, "CLOSED_retained_OK")
    detach_physical(physical, physical_screen, false)
    process.unlisten(physical_boot)
    process.unlisten(physical_ready)
    local probe_store, probe_error = open_store("bee.client.db:left")
    if not probe_store then error(tostring(probe_error)) end
    local probe_state = store.read(probe_store)
    if not probe_state or not probe_state.targets[1] then error("Missing close target") end
    local close_target = probe_state.targets[1]
    assert(probe_state.scene.windows[1].mode == "fullscreen", "Initial fullscreen option was not applied")
    assert(store.close(probe_store))
    -- Seed a separate desktop's declared target through the store API before
    -- its sole writer starts. No mount, PID or grant is copied.
    local observer_store = assert(open_store("bee.client.db:observer"))
    assert(store.write(observer_store, probe_state))
    assert(store.close(observer_store))
    command(left_screen, "bee_size=$(stty size); bee_observer=clean; printf 'OBSERVER_BASE_%s_END\\n' \"$$\"")
    local observer, observer_screen = start("observer", 75, false)
    wait_text(observer_screen, "OBSERVER_BASE_")
    command(observer_screen, "bee_observer=changed")
    wait_text(observer_screen, "View is read-only")
    assert(observer_screen:resize(65, 26))
    key(observer_screen, "f12")
    local observer_renderer = assert(renderers:receive())
    assert(tostring(observer_renderer:from()) == observer)
    local observer_data: unknown = observer_renderer:payload():data()
    if type(observer_data) ~= "table" or type(observer_data.renderer) ~= "string" then error("Missing observer renderer") end
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "observer-f12", op = "render",
        workspace_id = workspace_id, recipient = observer, renderer = observer_data.renderer}))
    result("observer-f12")
    command(left_screen, "test \"$bee_observer\" = clean && test \"$bee_size\" = \"$(stty size)\" && printf 'OBSERVER_F12_%s_END\\n' \"$bee_observer\"")
    wait_text(left_screen, "OBSERVER_F12_clean_END")
    wait_text(observer_screen, "OBSERVER_F12_clean_END")
    assert(process.terminate(observer))
    local observer_deadline = time.after("3s")
    while true do
        local selected = channel.select({events:case_receive(), observer_deadline:case_receive()})
        if not selected.ok or selected.channel == observer_deadline then error("Observer desktop did not exit") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == observer then
            assert(desktops.exited(retained_desktops, event)); break
        end
    end
    command(left_screen, "printf 'OBSERVER_GONE_%s_END\\n' \"$bee_observer\"")
    wait_text(left_screen, "OBSERVER_GONE_clean_END")
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
        local database, err = open_store("bee.client.db:" .. label)
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
        if event.kind == process.event.EXIT and tostring(event.from) == left then
            assert(desktops.exited(retained_desktops, event)); break
        end
    end
    command(right_screen, "printf 'SURVIVED_%s_EXIT\\n' \"$bee_desktop\"")
    wait_text(right_screen, "SURVIVED_right_EXIT")
    local database, database_error = open_store("bee.client.db:left")
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
    -- Abrupt client loss has no save/quit handshake. The host must retain the
    -- application while a fresh client recovers the committed desktop identity.
    local before_crash = assert(open_store("bee.client.db:left"))
    local desktop_id = before_crash.client_id
    assert(store.close(before_crash))
    assert(process.terminate(resumed))
    local crash_deadline = time.after("3s")
    while true do
        local selected = channel.select({events:case_receive(), crash_deadline:case_receive()})
        if not selected.ok or selected.channel == crash_deadline then error("Crashed client did not exit") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == resumed then
            assert(desktops.exited(retained_desktops, event)); break
        end
    end
    resumed, resumed_screen = start("left", 100, false)
    local after_crash = assert(open_store("bee.client.db:left"))
    local recovered = assert(store.read(after_crash))
    assert(after_crash.client_id == desktop_id, "Client loss replaced the durable desktop identity")
    assert(#recovered.targets == 1 and recovered.targets[1].instance_id == target.instance_id
        and recovered.targets[1].view_id == target.view_id, "Client loss replaced the retained application")
    assert(store.close(after_crash))
    key(resumed_screen, "w", true)
    wait_text(resumed_screen, "Close terminal?")
    key(resumed_screen, "tab")
    key(resumed_screen, "enter")
    wait_absent(resumed_screen, "Close terminal?", "accept", events)
    local closed = false
    local final_store, final_error = open_store("bee.client.db:left")
    if not final_store then error(tostring(final_error)) end
    for _ = 1, 500 do
        local final_state = store.read(final_store)
        if final_state and #final_state.targets == 0 then closed = true; break end
        time.sleep("10ms")
    end
    assert(store.close(final_store))
    assert(closed, "Confirmed close did not retire the selected target")
    local appearance_store = open_store("bee.client.db:left")
    if not appearance_store then error("Cannot open client appearance store") end
    local before = assert(store.read(appearance_store))
    local other_store = open_store("bee.client.db:right")
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
    process.terminate(right)
    local cleanup_deadline = time.after("3s")
    while next(retained_desktops.desktops) ~= nil do
        local selected = channel.select({events:case_receive(), cleanup_deadline:case_receive()})
        if not selected.ok or selected.channel == cleanup_deadline then error("Desktop resource cleanup did not complete") end
        desktops.exited(retained_desktops, selected.value)
    end
    process.terminate(host)
    log:info("DESKTOP_CLIENT_PROBE_COMPLETE")
end
local function checked_main(mode: string?)
    local ok, failure = pcall(main, mode)
    if not ok then
        log:error("DESKTOP_CLIENT_PROBE_FAILURE", {error = tostring(failure)})
        error(failure)
    end
end
return {main = checked_main}
