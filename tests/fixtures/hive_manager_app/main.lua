-- MIT. Drives the real manager through its normal broker attachment. This fixture
-- is packed only into disposable acceptance packs.
local process = require("process")
local time = require("time")
local security = require("security")
local tty = require("tty")
local appearance = require("appearance")
local io = require("io")
local WORKSPACE = string.rep("a", 32)
local function wait_text(view: tty.Viewport, text: string)
    for _ = 1, 500 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows, "\n"):find(text, 1, true) then return end
        time.sleep("10ms")
    end
    error("missing viewport text: " .. text)
end
local function key(view: tty.Viewport, value: string)
    assert(view:send({type = "key", key = value, key_type = #value == 1 and "runes" or value, action = "press"}))
end
local function main(mode: string?)
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local dialogs = assert(process.listen("bee.interaction.state", {message = true}))
    local slow_entered = assert(process.listen("bee.hive_manager_probe.slow_entered", {message = true}))
    local broker_policy = assert(security.policy("bee.security.desktop:broker_policy"))
    local boundary = assert(security.policy("bee.security:core_spawn_boundary"))
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(security.new_scope({broker_policy, boundary})):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    assert(catalogs:receive())
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.hive_manager:app", arguments = {}}))
    local opened: {[string]: unknown}? = nil
    while not opened do
        local message = assert(replies:receive())
        local data: unknown = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "open" then opened = data :: {[string]: unknown} end
    end
    assert(opened.error_code == "", "manager did not become ready: " .. tostring(opened.error))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local mount = ""
    while mount == "" do
        local message = assert(replies:receive())
        local data: unknown = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind" and data.op == "attached" then mount = tostring(data.mount) end
    end
    local view = assert(tty.attach(mount)); assert(view:send({type = "resize", width = 100, height = 30}))
    wait_text(view, "HIVE MANAGER")
    local function close()
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
        while true do
            local message = assert(replies:receive())
            local data: unknown = message:payload():data()
            if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "close" and data.op == "close" then
                assert(data.error_code == "", "manager close failed: " .. tostring(data.error)); return
            end
        end
    end
    if mode == "unavailable" then
        wait_text(view, "Hive supervisor unavailable: test supervisor unavailable")
        close()
    elseif mode == "slow" then
        wait_text(view, "ready")
        key(view, "enter")
        assert(slow_entered:receive())
        key(view, "t"); wait_text(view, "Hide details")
        local started = time.now()
        close()
        assert(time.now():sub(started):milliseconds() < 1000, "close waited for the suspended directory call")
    else
        wait_text(view, "ready")
        key(view, "enter"); wait_text(view, "main")
        key(view, "c")
        local state = assert(dialogs:receive())
        local data: unknown = state:payload():data()
        assert(type(data) == "table" and type(data.items) == "table" and data.items[1] ~= nil, "missing manager confirmation")
        local question = data.items[1] :: {[string]: unknown}
        -- The selection moves to another workspace while the question stands;
        -- accepting it must not redirect consent to the new selection.
        key(view, "down"); wait_text(view, "›replacement")
        assert(process.send(broker, "bee.interaction.response", {version = 1, request_id = question.request_id,
            id = question.id, instance_id = question.instance_id, action = "accept", value = ""}))
        wait_text(view, "Workspace selection changed")
        close()
    end
    view:close(); process.terminate(broker)
    io.print("BEE_HIVE_MANAGER_APP_PROBE: OK " .. tostring(mode))
end
return main
