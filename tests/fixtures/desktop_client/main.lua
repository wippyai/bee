-- MIT. Two actual desktop owners render into separate native terminal grants.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local store = require("store")
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
    error("Missing desktop output: " .. text)
end
local function command(view: tty.Viewport, value: string)
    assert(view:send({type = "paste", text = value}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
end
local function main()
    local owner = tostring(process.pid())
    local hosts = assert(process.listen("bee.host.ready", {message = true}))
    local clients = assert(process.listen("bee.client.ready", {message = true}))
    local renderers = assert(process.listen("bee.client.renderer", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local events = assert(process.events())
    local host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = owner}):with_scope(scope({
        "bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"})):spawn_monitored("bee.workspace:host", "bee:workers", owner)))
    local host_ready = assert(hosts:receive())
    assert(tostring(host_ready:from()) == host)
    local data: unknown = host_ready:payload():data()
    if type(data) ~= "table" or type(data.workspace_id) ~= "string" then error("Invalid host readiness") end
    local workspace_id = data.workspace_id
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
                "bee.client:main", "bee:workers", owner, host, workspace_id, "bee.client.db:" .. label, launch and "bee.console:app" or nil)))
        local ready = assert(clients:receive())
        assert(tostring(ready:from()) == client)
        assert(process.send(host, "bee.host.client", {version = 1, request_id = label .. "-admit", op = "admit",
            workspace_id = workspace_id, recipient = client, permissions = {open = true, close = true, control = true}}))
        result(label .. "-admit")
        local selected = assert(renderers:receive())
        assert(tostring(selected:from()) == client)
        local value: unknown = selected:payload():data()
        if type(value) ~= "table" or type(value.renderer) ~= "string" or value.workspace_id ~= workspace_id then error("Invalid renderer selection") end
        assert(process.send(host, "bee.host.client", {version = 1, request_id = label .. "-render", op = "render",
            workspace_id = workspace_id, recipient = client, renderer = value.renderer}))
        result(label .. "-render")
        wait_text(screen, "Terminal")
        if launch then
            command(screen, "bee_desktop=" .. label .. "; printf 'DESKTOP_%s_OK\\n' \"$bee_desktop\"")
            wait_text(screen, "DESKTOP_" .. label .. "_OK")
        else
            command(screen, "printf 'RESUMED_%s_OK\\n' \"$bee_desktop\"")
            wait_text(screen, "RESUMED_" .. label .. "_OK")
        end
        return client, screen
    end
    local left, left_screen = start("left", 100, true)
    local right, right_screen = start("right", 120, true)
    command(left_screen, "printf 'STILL_%s_HERE\\n' \"$bee_desktop\"")
    wait_text(left_screen, "STILL_left_HERE")
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
    local mounted = assert(replies:receive())
    assert(tostring(mounted:from()) == host)
    local mounted_data: unknown = mounted:payload():data()
    if type(mounted_data) ~= "table" or mounted_data.request_id ~= "retained" or mounted_data.op ~= "attached"
        or mounted_data.error_code ~= "" or type(mounted_data.mount) ~= "string" then error("Retained Terminal did not attach") end
    local retained, attach_error = tty.attach(mounted_data.mount)
    if not retained then error(tostring(attach_error)) end
    command(retained, "printf 'RETAINED_%s_PROCESS\\n' \"$bee_desktop\"")
    wait_text(retained, "RETAINED_left_PROCESS")
    retained:close()
    -- A fresh client execution imports no host checkpoint and selects no new app.
    local resumed, resumed_screen = start("left", 100, false)
    process.terminate(resumed)
    resumed_screen:close()
    process.terminate(right)
    process.terminate(host)
    left_screen:close(); right_screen:close()
end
return {main = main}
