-- Real bundled Terminal behind a detached Bee broker; no physical TTY owner.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local decode = require("decode")
local appearance = require("appearance")
local store = require("store")
local M = {}
function M.main()
    local owner = tostring(process.pid())
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local database = assert(store.open())
    local workspace_id = assert(database:identity())
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:broker_policy", "bee:core_spawn_boundary", "bee.attachment_probe:naming_policy"}) do
        local policy, err = security.policy(name)
        if err then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local broker = tostring(assert(process.with_options({}):with_context({
        ["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace_id,
    }):with_scope(security.new_scope(policies)):spawn_monitored(
        "bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    assert(catalogs:receive():from() == broker)
    local endpoint = "bee.attachment_probe.host"
    assert(process.registry.lookup(endpoint) == broker)
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == broker)
            local value = decode.reply(message:payload():data())
            if not value then error("Invalid reply") end
            assert(decode.belongs(value, workspace_id))
            assert(value.op ~= "closed", "Detached terminal stopped")
            if value.request_id == id and value.op == op then return value end
        end
        error("Reply channel closed")
    end
    local function bind(id: string, target: string)
        assert(process.send(endpoint, "bee.app.request", {version = 1, request_id = id,
            op = "bind", workspace_id = workspace_id, recipient = target}))
    end
    local function command(view: tty.Viewport, text: string)
        assert(view:send({type = "paste", text = text}))
        assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
    end
    local function wait_for(view: tty.Viewport, pattern: string): string
        for _ = 1, 300 do
            local frame = assert(view:snapshot())
            local match = table.concat(frame.rows, "\n"):match(pattern)
            if match then return match end
            time.sleep("10ms")
        end
        error("Terminal output missing: " .. pattern)
    end
    assert(process.send(endpoint, "bee.app.request", {version = 1, request_id = "open-terminal",
        op = "open", workspace_id = workspace_id, definition_id = "bee.console:app"}))
    local opened = reply("open-terminal", "open")
    assert(opened.error_code == "" and opened.mount == "")
    bind("first-terminal", owner)
    local mounted = reply("first-terminal", "attached")
    assert(mounted.error_code == "" and mounted.instance_id == opened.instance_id)
    assert(reply("first-terminal", "bind").error_code == "")
    local first, first_error = tty.attach(mounted.mount)
    if not first then error(tostring(first_error)) end
    command(first, "bee_probe=retained; printf 'BEE_PID_%s\\n' \"$$\"")
    local native_pid = wait_for(first, "BEE_PID_(%d+)")
    bind("detach-terminal", "")
    assert(reply("detach-terminal", "bind").error_code == "")
    local sent, denied = first:send({type = "key", key = "x", key_type = "runes", action = "press"})
    assert(not sent and denied, "Detached terminal retained input")
    time.sleep("400ms")
    bind("second-terminal", owner)
    local rebound = reply("second-terminal", "attached")
    assert(rebound.error_code == "" and rebound.instance_id == opened.instance_id and rebound.mount ~= mounted.mount)
    assert(reply("second-terminal", "bind").error_code == "")
    local second, second_error = tty.attach(rebound.mount)
    if not second then error(tostring(second_error)) end
    command(second, "printf 'BEE_REJOIN_%s_%s\\n' \"$$\" \"$bee_probe\"")
    wait_for(second, "BEE_REJOIN_" .. native_pid .. "_retained")
    assert(second:resize(90, 32))
    command(second, "printf 'BEE_SIZE_%s\\n' \"$(stty size)\"")
    wait_for(second, "BEE_SIZE_32 90")
    first:close(); second:close()
    assert(process.send(endpoint, "bee.app.request", {version = 1, request_id = "stop-terminal",
        op = "shutdown", workspace_id = workspace_id}))
    assert(reply("stop-terminal", "shutdown").error_code == "")
    database:close()
    process.terminate(broker)
    process.unlisten(replies); process.unlisten(catalogs)
end
return M
