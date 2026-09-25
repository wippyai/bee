-- MIT. Actual retained supervisor, separate display executions, same live shell.
local process = require("process")
local store = require("store")
local security = require("security")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local logger = require("logger")
local registry = require("registry")
local log = logger:named("bee.retained_probe")
local function main(mode: string?)
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.retained.ready", {message = true}))
    local replies = assert(process.listen("bee.retained.result", {message = true}))
    local launches = assert(process.listen("bee.retained.launched", {message = true}))
    local catalogs = assert(process.listen("bee.retained.desktops_result", {message = true}))
    local activated = assert(process.listen("bee.retained.activated", {message = true}))
    local replaced_clients = assert(process.listen("bee.retained.replaced", {message = true}))
    local boots = assert(process.listen("physical.boot", {message = true}))
    local displays = assert(process.listen("physical.ready", {message = true}))
    local events = assert(process.events())
    local forged = assert(process.listen("forged.sent", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:desktop_policy", "bee.security.desktop:retained_supervisor_spawn_policy", "bee.security.desktop:desktop_catalog_policy", "bee.security.desktop:desktop_catalog_resource_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    local supervisor = tostring(assert(process.with_options({}):with_context({["bee.retained_owner"] = owner})
        :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:retained", "bee:workers", owner, {root_ref = "bee.environment:workspace_root", subpath = ""}, "bee.console:app")))
    local deadline = time.after("10s")
    local selected = channel.select({ready:case_receive(), events:case_receive(), deadline:case_receive()})
    assert(selected.ok and selected.channel == ready, "Retained supervisor did not become ready")
    local message = selected.value
    assert(tostring(message:from()) == supervisor)
    local value: unknown = message:payload():data()
    assert(type(value) == "table" and type(value.workspace_id) == "string" and type(value.desktop_id) == "string")
    local workspace_id, desktop_id = value.workspace_id, value.desktop_id
    local initial_store, open_error = store.open("bee.environment:client_db", workspace_id)
    if not initial_store then error(tostring(open_error)) end
    local initial_layout = store.read(initial_store)
    assert(initial_layout and initial_layout.appearance_mode == "inherit", "Fresh primary display did not inherit node defaults")
    assert(store.close(initial_store))
    local forger_policy = assert(security.policy("bee.desktop_client_probe:root_policy"))
    local forger = tostring(assert(process.with_options({}):with_scope(security.new_scope({forger_policy}))
        :spawn("bee.desktop_client_probe:forger", "bee:workers", owner, supervisor, workspace_id, desktop_id)))
    assert(tostring(assert(forged:receive()):from()) == forger)
    local sequence = 0
    local function request(recipient: string, op: string, mode: string?, selected_id: string?): (string, string)
        sequence = sequence + 1
        local id = tostring(sequence)
        local target_id = selected_id or desktop_id
        assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id,
            desktop_id = target_id, request_id = id, recipient = recipient, op = op, mode = mode}))
        local timeout = time.after("3s")
        local response = channel.select({replies:case_receive(), timeout:case_receive()})
        assert(response.ok and response.channel == replies, "Missing retained reply")
        local reply = response.value
        assert(tostring(reply:from()) == supervisor)
        local data: unknown = reply:payload():data()
        assert(type(data) == "table" and data.request_id == id and data.workspace_id == workspace_id
            and data.desktop_id == target_id and type(data.mount) == "string" and type(data.error_code) == "string")
        return data.mount, data.error_code
    end
    local function launch(recipient: string, name: string, args: {string}, selected_id: string?): string
        sequence = sequence + 1
        local id = "launch-" .. tostring(sequence)
        local target_id = selected_id or desktop_id
        assert(process.send(supervisor, "bee.retained.launch", {version = 1, workspace_id = workspace_id,
            desktop_id = target_id, request_id = id, recipient = recipient, name = name, arguments = args}))
        local timeout = time.after("5s")
        local response = channel.select({launches:case_receive(), timeout:case_receive()})
        assert(response.ok and response.channel == launches, "Missing broker launch result")
        local reply = response.value
        assert(tostring(reply:from()) == supervisor)
        local data: unknown = reply:payload():data()
        assert(type(data) == "table" and data.request_id == id and data.workspace_id == workspace_id
            and data.desktop_id == target_id and type(data.error_code) == "string")
        if data.error_code == "" then
            assert(type(data.id) == "string" and data.id ~= "" and type(data.instance_id) == "string" and data.instance_id ~= "")
        else assert(data.id == "" and data.instance_id == "") end
        return data.error_code
    end
    local function wait_text(view: tty.Viewport, needle: string)
        for _ = 1, 500 do
            local snapshot = view:snapshot()
            if snapshot and table.concat(snapshot.rows, "\n"):find(needle, 1, true) then return end
            time.sleep("10ms")
        end
        local last = view:snapshot()
        error("Missing retained text: " .. needle .. "\n" .. (last and table.concat(last.rows, "\n") or "No frame"))
    end
    local function attach(mode: string?, selected_id: string?): (string, tty.Viewport)
        local screen, screen_error = tty.viewport({width = 100, height = 32})
        if not screen then error(tostring(screen_error)) end
        local root_policy = assert(security.policy("bee.desktop_client_probe:root_policy"))
        local pid = tostring(assert(process.with_options({terminal = assert(screen:grant())})
            :with_scope(security.new_scope({root_policy})):spawn_monitored("bee.desktop_client_probe:physical", "bee:workers", owner)))
        assert(tostring(assert(boots:receive()):from()) == pid)
        local mount, code = request(pid, "attach", mode or "control", selected_id)
        for _ = 1, 300 do
            if code ~= "busy" then break end
            time.sleep("10ms"); mount, code = request(pid, "attach", mode or "control", selected_id)
        end
        assert(code == "", "Supervisor did not release exited controller")
        assert(process.send(pid, "physical.configure", {mount = mount}))
        assert(tostring(assert(displays:receive()):from()) == pid)
        wait_text(screen, selected_id and "BEE" or "$ ")
        return pid, screen
    end
    local function command(screen: tty.Viewport, text: string)
        assert(screen:send({type = "paste", text = text}))
        assert(screen:send({type = "key", key = "", key_type = "enter", action = "press"}))
    end
    local function storage(op: string, identity: string?, expected: string, count: integer)
        sequence = sequence + 1
        local id = "storage-" .. tostring(sequence)
        assert(process.send(supervisor, "bee.retained.desktops", {version = 1, workspace_id = workspace_id,
            request_id = id, op = op, desktop_id = identity}))
        local response = channel.select({catalogs:case_receive(), time.after("6s"):case_receive()})
        assert(response.ok and response.channel == catalogs, "Missing desktop storage reply")
        local reply = response.value
        assert(tostring(reply:from()) == supervisor)
        local data: unknown = reply:payload():data()
        assert(type(data) == "table" and data.request_id == id and data.workspace_id == workspace_id
            and data.code == expected and type(data.desktops) == "table" and #data.desktops == count,
            "Invalid desktop storage result")
        if count > 0 then
            local first: unknown = data.desktops[1]
            assert(type(first) == "table" and first.desktop_id == desktop_id and first.is_default == true)
        end
    end
    storage("list", nil, "OK", 1)
    storage("allocate", string.rep("a", 32), "OK", 0)
    storage("allocate", string.rep("a", 32), "OK", 0)
    storage("allocate", desktop_id, "CONFLICT", 0)
    storage("list", nil, "OK", 2)
    local first, first_screen = attach()
    command(first_screen, "bee_owner=alive; printf 'OWNER_%s_OK\\n' \"$bee_owner\"")
    wait_text(first_screen, "OWNER_alive_OK")
    local extra_id = string.rep("a", 32)
    local function activate(id: string, expected: string?): string
        sequence = sequence + 1
        local correlation = "activate-" .. tostring(sequence)
        assert(process.send(supervisor, "bee.retained.activate", {version = 1, workspace_id = workspace_id,
            desktop_id = id, request_id = correlation}))
        local response = channel.select({activated:case_receive(), time.after("12s"):case_receive()})
        assert(response.ok and response.channel == activated, "Missing desktop activation reply")
        local message = response.value
        assert(tostring(message:from()) == supervisor)
        local data: unknown = message:payload():data()
        assert(type(data) == "table" and data.request_id == correlation and data.desktop_id == id
            and type(data.error_code) == "string", "Invalid desktop activation result")
        if expected then assert(data.error_code == expected, "Unexpected desktop activation result: " .. tostring(data.error)) end
        return data.error_code
    end
    activate(extra_id, "")
    activate(extra_id, "")
    local extra, extra_screen = attach("control", extra_id)
    assert(launch(extra, "terminal", {}, extra_id) == "")
    wait_text(extra_screen, "$ ")
    command(extra_screen, "bee_extra=separate; printf 'OWNER_EXTRA_%s_OK\\n' \"$bee_extra\"")
    wait_text(extra_screen, "OWNER_EXTRA_separate_OK")
    local extra_shell = ""
    if mode == "client-upgrade" then
        command(first_screen, "printf 'RETAINED_BEFORE_FIRST_%s_END\\n' \"$$\"")
        wait_text(first_screen, "RETAINED_BEFORE_FIRST_")
        local first_before = table.concat(assert(first_screen:snapshot()).rows, "\n")
        local first_shell = assert(first_before:match("RETAINED_BEFORE_FIRST_(%d+)_END"))
        command(extra_screen, "printf 'RETAINED_BEFORE_EXTRA_%s_END\\n' \"$$\"")
        wait_text(extra_screen, "RETAINED_BEFORE_EXTRA_")
        local extra_before = table.concat(assert(extra_screen:snapshot()).rows, "\n")
        extra_shell = assert(extra_before:match("RETAINED_BEFORE_EXTRA_(%d+)_END"))
        local entry = assert(registry.get("bee.client:main"))
        entry.meta.handoff_probe = "retained-client-definition-changed"
        local changes = assert(registry.snapshot()):changes()
        changes:update(entry)
        assert(changes:apply())
        local updated: {[string]: boolean} = {}
        local timeout = time.after("12s")
        while not updated[desktop_id] or not updated[extra_id] do
            local selected = channel.select({replaced_clients:case_receive(), events:case_receive(), timeout:case_receive()})
            assert(selected.ok and selected.channel ~= timeout, "Retained clients did not reattach after definition change")
            if selected.channel == events then
                local event = selected.value
                assert(tostring(event.from) ~= supervisor, "Retained supervisor exited during client replacement")
            else
                local message = selected.value
                assert(tostring(message:from()) == supervisor)
                local value: unknown = message:payload():data()
                assert(type(value) == "table" and value.version == 1 and value.schema == 1
                    and value.workspace_id == workspace_id and type(value.pid) == "string")
                updated[value.display_id] = true
                local changed_id: string = value.display_id :: string
                local recipient = changed_id == desktop_id and first or extra
                local mount, code = request(recipient, "attach", "control", changed_id)
                assert(code == "", "Physical grant reissue failed: " .. code)
                assert(process.send(recipient, "physical.configure", {mount = mount}))
                assert(tostring(assert(displays:receive()):from()) == recipient)
            end
        end
        command(first_screen, "printf 'RETAINED_UPGRADE_FIRST_%s_END\\n' \"$$\"")
        wait_text(first_screen, "RETAINED_UPGRADE_FIRST_" .. first_shell .. "_END")
        command(extra_screen, "printf 'RETAINED_UPGRADE_EXTRA_%s_END\\n' \"$$\"")
        wait_text(extra_screen, "RETAINED_UPGRADE_EXTRA_" .. extra_shell .. "_END")
    end
    local before_rejoin = assert(extra_screen:snapshot()).rows[1]
    assert(extra_screen:send({type = "key", key = "f12", key_type = "f12", action = "press"}))
    local replaced = false
    if mode == "client-upgrade" then
        local selected = channel.select({replaced_clients:case_receive(), time.after("5s"):case_receive()})
        if selected.ok and selected.channel == replaced_clients then
            local message = selected.value
            local value: unknown = message:payload():data()
            replaced = tostring(message:from()) == supervisor and type(value) == "table"
                and value.display_id == extra_id and value.workspace_id == workspace_id
        end
        assert(replaced, "Replaced client presenter did not become ready after F12")
        command(extra_screen, "printf 'RETAINED_F12_%s_END\\n' \"$$\"")
        wait_text(extra_screen, "RETAINED_F12_" .. extra_shell .. "_END")
    else
        for _ = 1, 500 do
            local frame = extra_screen:snapshot()
            if frame and frame.rows[1] ~= before_rejoin and table.concat(frame.rows, "\n"):find("OWNER_EXTRA_separate_OK", 1, true) then replaced = true; break end
            time.sleep("10ms")
        end
    end
    assert(replaced, "Additional desktop presenter was not replaced")
    assert(extra_screen:send({type = "key", key = "q", key_type = "runes", action = "press", ctrl = true}))
    time.sleep("100ms")
    local _, extra_detached = request(extra, "detach", nil, extra_id)
    assert(extra_detached == "")
    process.terminate(extra)
    local extra_timeout = time.after("3s")
    while true do
        local stopped = channel.select({events:case_receive(), extra_timeout:case_receive()})
        assert(stopped.ok and stopped.channel == events, "Additional physical client did not exit")
        if stopped.value.kind == process.event.EXIT and tostring(stopped.value.from) == extra then break end
        assert(tostring(stopped.value.from) ~= supervisor, "Supervisor stopped with additional display")
    end
    extra_screen:close()
    local resumed_code = activate(extra_id, nil)
    for _ = 1, 300 do
        if resumed_code ~= "BUSY" then break end
        time.sleep("10ms"); resumed_code = activate(extra_id, nil)
    end
    assert(resumed_code == "", "Saved desktop did not reactivate")
    local resumed, resumed_screen = attach("control", extra_id)
    wait_text(resumed_screen, "OWNER_EXTRA_separate_OK")
    command(resumed_screen, "printf 'EXTRA_RESTORED_%s_OK\\n' \"$bee_extra\"")
    wait_text(resumed_screen, "EXTRA_RESTORED_separate_OK")
    assert(select(2, request(resumed, "detach", nil, extra_id)) == "")
    process.terminate(resumed)
    local resumed_timeout = time.after("3s")
    while true do
        local stopped = channel.select({events:case_receive(), resumed_timeout:case_receive()})
        assert(stopped.ok and stopped.channel == events, "Resumed physical client did not exit")
        if stopped.value.kind == process.event.EXIT and tostring(stopped.value.from) == resumed then break end
        assert(tostring(stopped.value.from) ~= supervisor, "Supervisor stopped with resumed display")
    end
    resumed_screen:close()
    command(first_screen, "printf 'OWNER_FIRST_%s_OK\\n' \"$bee_owner\"")
    wait_text(first_screen, "OWNER_FIRST_alive_OK")
    local _, competing = request(owner, "attach", "control")
    assert(competing == "busy", "Competing controller stole desktop")
    local observer, observer_screen = attach("observe")
    assert(launch(observer, "terminal", {}) == "DENIED", "Observer launched an application")
    assert(launch(first, "missing-command", {}) == "INVALID_ARGUMENT", "Unknown command was accepted")
    assert(process.terminate(first))
    local exit_deadline = time.after("3s")
    while true do
        local event = channel.select({events:case_receive(), exit_deadline:case_receive()})
        assert(event.ok and event.channel == events, "Display did not exit")
        if event.value.kind == process.event.EXIT then
            assert(tostring(event.value.from) == first, "Supervisor exited with display")
            break
        end
    end
    first_screen:close()
    local second, second_screen = attach()
    command(second_screen, "printf 'OWNER_REJOIN_%s_OK\\n' \"$bee_owner\"")
    wait_text(second_screen, "OWNER_REJOIN_alive_OK")
    local _, detached = request(second, "detach", nil)
    assert(detached == "")
    assert(launch(second, "terminal", {}) == "DENIED", "Retired controller launched an application")
    process.terminate(second)
    second_screen:close()
    local third, third_screen = attach()
    command(third_screen, "printf 'OWNER_DETACH_%s_OK\\n' \"$bee_owner\"")
    wait_text(third_screen, "OWNER_DETACH_alive_OK")
    assert(launch(third, "terminal", {"bash", "-c", "printf '%s\\n' \"$1\"; exec bash -i", "bee-launch", "LITERAL ; $(exit 4) two words"}) == "")
    wait_text(third_screen, "LITERAL ; $(exit 4) two words")
    assert(third_screen:send({type = "key", key = "q", key_type = "runes", action = "press", ctrl = true}))
    time.sleep("100ms")
    local reopened = activate(desktop_id, nil)
    for _ = 1, 300 do
        if reopened ~= "BUSY" then break end
        time.sleep("10ms"); reopened = activate(desktop_id, nil)
    end
    assert(reopened == "", "Default display did not reactivate after close")
    local fourth, fourth_screen = attach()
    wait_text(fourth_screen, "LITERAL ; $(exit 4) two words")
    assert(select(2, request(fourth, "detach", nil)) == "")
    process.terminate(fourth)
    fourth_screen:close()
    process.terminate(supervisor)
    process.terminate(third)
    process.terminate(observer)
    observer_screen:close()
    third_screen:close()
    log:info("RETAINED_SUPERVISOR_PROBE_COMPLETE")
end
local function checked_main(mode: string?)
    local ok, failure = pcall(main, mode)
    if not ok then
        log:error("RETAINED_SUPERVISOR_PROBE_FAILURE", {error = tostring(failure)})
        error(failure)
    end
end
return {main = checked_main, client_upgrade = function() checked_main("client-upgrade") end}
