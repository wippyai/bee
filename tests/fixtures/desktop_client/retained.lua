-- MIT. Actual retained supervisor, separate display executions, same live shell.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local logger = require("logger")
local log = logger:named("bee.retained_probe")
local function main()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.retained.ready", {message = true}))
    local replies = assert(process.listen("bee.retained.result", {message = true}))
    local boots = assert(process.listen("physical.boot", {message = true}))
    local displays = assert(process.listen("physical.ready", {message = true}))
    local events = assert(process.events())
    local forged = assert(process.listen("forged.sent", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:desktop_policy", "bee:retained_supervisor_spawn_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    local supervisor = tostring(assert(process.with_options({}):with_context({["bee.retained_owner"] = owner})
        :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:retained", "bee:workers", owner, "bee.console:app")))
    local deadline = time.after("10s")
    local selected = channel.select({ready:case_receive(), events:case_receive(), deadline:case_receive()})
    assert(selected.ok and selected.channel == ready, "Retained supervisor did not become ready")
    local message = selected.value
    assert(tostring(message:from()) == supervisor)
    local value: unknown = message:payload():data()
    assert(type(value) == "table" and type(value.workspace_id) == "string" and type(value.desktop_id) == "string")
    local workspace_id, desktop_id = value.workspace_id, value.desktop_id
    local forger_policy = assert(security.policy("bee.desktop_client_probe:root_policy"))
    local forger = tostring(assert(process.with_options({}):with_scope(security.new_scope({forger_policy}))
        :spawn("bee.desktop_client_probe:forger", "bee:workers", owner, supervisor, workspace_id, desktop_id)))
    assert(tostring(assert(forged:receive()):from()) == forger)
    local sequence = 0
    local function request(recipient: string, op: string, mode: string?): (string, string)
        sequence = sequence + 1
        local id = tostring(sequence)
        assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id,
            desktop_id = desktop_id, request_id = id, recipient = recipient, op = op, mode = mode}))
        local timeout = time.after("3s")
        local response = channel.select({replies:case_receive(), timeout:case_receive()})
        assert(response.ok and response.channel == replies, "Missing retained reply")
        local reply = response.value
        assert(tostring(reply:from()) == supervisor)
        local data: unknown = reply:payload():data()
        assert(type(data) == "table" and data.request_id == id and data.workspace_id == workspace_id
            and data.desktop_id == desktop_id and type(data.mount) == "string" and type(data.error_code) == "string")
        return data.mount, data.error_code
    end
    local function wait_text(view: tty.Viewport, needle: string)
        for _ = 1, 500 do
            local snapshot = view:snapshot()
            if snapshot and table.concat(snapshot.rows, "\n"):find(needle, 1, true) then return end
            time.sleep("10ms")
        end
        error("Missing retained text: " .. needle)
    end
    local function attach(): (string, tty.Viewport)
        local screen, screen_error = tty.viewport({width = 100, height = 32})
        if not screen then error(tostring(screen_error)) end
        local root_policy = assert(security.policy("bee.desktop_client_probe:root_policy"))
        local pid = tostring(assert(process.with_options({terminal = assert(screen:grant())})
            :with_scope(security.new_scope({root_policy})):spawn_monitored("bee.desktop_client_probe:physical", "bee:workers", owner)))
        assert(tostring(assert(boots:receive()):from()) == pid)
        local mount, code = request(pid, "attach", "control")
        for _ = 1, 300 do
            if code ~= "busy" then break end
            time.sleep("10ms"); mount, code = request(pid, "attach", "control")
        end
        assert(code == "", "Supervisor did not release exited controller")
        assert(process.send(pid, "physical.configure", {mount = mount}))
        assert(tostring(assert(displays:receive()):from()) == pid)
        wait_text(screen, "$ ")
        return pid, screen
    end
    local function command(screen: tty.Viewport, text: string)
        assert(screen:send({type = "paste", text = text}))
        assert(screen:send({type = "key", key = "", key_type = "enter", action = "press"}))
    end
    local first, first_screen = attach()
    command(first_screen, "bee_owner=alive; printf 'OWNER_%s_OK\\n' \"$bee_owner\"")
    wait_text(first_screen, "OWNER_alive_OK")
    local _, competing = request(owner, "attach", "control")
    assert(competing == "busy", "Competing controller stole desktop")
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
    process.terminate(second)
    second_screen:close()
    local third, third_screen = attach()
    command(third_screen, "printf 'OWNER_DETACH_%s_OK\\n' \"$bee_owner\"")
    wait_text(third_screen, "OWNER_DETACH_alive_OK")
    assert(third_screen:send({type = "key", key = "q", key_type = "runes", action = "press", ctrl = true}))
    wait_text(third_screen, "Quit Bee?")
    assert(third_screen:send({type = "key", key = "tab", key_type = "tab", action = "press"}))
    assert(third_screen:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
    local stopped = time.after("5s")
    while true do
        local event = channel.select({events:case_receive(), stopped:case_receive()})
        assert(event.ok and event.channel == events, "Supervisor did not finish negotiated shutdown")
        if event.value.kind == process.event.EXIT and tostring(event.value.from) == supervisor then break end
    end
    process.terminate(third)
    third_screen:close()
    log:info("RETAINED_SUPERVISOR_PROBE_COMPLETE")
end
local function checked_main()
    local ok, failure = pcall(main)
    if not ok then
        log:error("RETAINED_SUPERVISOR_PROBE_FAILURE", {error = tostring(failure)})
        error(failure)
    end
end
local function forger(owner: string, supervisor: string, workspace_id: string, desktop_id: string)
    assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id,
        desktop_id = desktop_id, request_id = "forged", recipient = owner, op = "attach", mode = "control"}))
    assert(process.send(owner, "forged.sent", {}))
end
return {main = checked_main, forger = forger}
