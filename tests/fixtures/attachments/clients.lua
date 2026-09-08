-- MIT. Actual actor clients, supervised admission and retained native PTYs.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local decode = require("decode")
local contract = require("contract")
type View = {id: string, instance_id: string, native_pid: string}
local M = {}
local function command(view: tty.Viewport, text: string)
    assert(view:send({type = "paste", text = text}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
end
local function wait_for(view: tty.Viewport, pattern: string): string
    for _ = 1, 300 do
        local frame = assert(view:snapshot())
        local found = table.concat(frame.rows):match(pattern)
        if found then return found end
        time.sleep("10ms")
    end
    error("Missing native output: " .. pattern)
end
function M.client(owner: string, host: string, workspace_id: string, label: string)
    local admissions = assert(process.listen("bee.host.admitted", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local commands = assert(process.listen("bee.client.command", {message = true}))
    local function status(phase: string, view: View?)
        assert(process.send(owner, "bee.client.status", {phase = phase, view = view}))
    end
    local function admission(): string
        local message = assert(admissions:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.workspace_id ~= workspace_id or type(data.connection_id) ~= "string" then error("Invalid admission") end
        return data.connection_id
    end
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local value = decode.reply(message:payload():data())
            if not value then error("Invalid client reply") end
            assert(decode.belongs(value, workspace_id))
            if value.request_id == id and value.op == op then return value end
        end
        error("Reply channel closed")
    end
    status("ready")
    local connection_id = admission()
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = workspace_id,
        connection_id = connection_id, definition_id = "bee.console:app"}))
    local opened = reply("open", "open")
    assert(opened.error_code == "" and opened.mount == "" and opened.resume_state == "")
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = workspace_id,
        connection_id = connection_id, id = opened.id, instance_id = opened.instance_id}))
    local bound = reply("bind", "attached")
    assert(bound.error_code == "" and reply("bind", "bind").error_code == "")
    local view, view_error = tty.attach(bound.mount)
    if not view then error(tostring(view_error)) end
    command(view, "bee_client=" .. label .. "; printf 'BEE_CLIENT_%s_%s\\n' \"$bee_client\" \"$$\"")
    local native_pid = wait_for(view, "BEE_CLIENT_" .. label .. "_(%d+)")
    status("opened", {id = opened.id, instance_id = opened.instance_id, native_pid = native_pid})
    while true do
        local message = assert(commands:receive())
        assert(message:from() == owner)
        local op: unknown = message:payload():data()
        if op == "check" then
            command(view, "printf 'BEE_CHECK_%s_%s\\n' \"$bee_client\" \"$$\"")
            wait_for(view, "BEE_CHECK_" .. label .. "_" .. native_pid)
            status("checked")
        elseif op == "stale" then
            local frame, err = view:snapshot()
            assert(not frame and err, "Detached client retained its frame")
            local sent, input_error = view:send({type = "key", key = "x", key_type = "runes", action = "press"})
            assert(not sent and input_error, "Detached client retained input")
            status("stale")
        elseif op == "readmit" then
            local fresh = admission()
            assert(fresh ~= connection_id)
            for _, token in ipairs({connection_id, fresh}) do
                assert(process.send(host, "bee.app.request", {version = 1, request_id = "forbidden", op = "open", workspace_id = workspace_id,
                    connection_id = token, definition_id = "bee.console:app"}))
                assert(reply("forbidden", "open").error_code == "permission_denied")
            end
            connection_id = fresh
            status("denied")
        elseif op == "exit" then break
        else error("Invalid client test command") end
    end
    -- Deliberately rely on execution cleanup; the host must retire this admission.
    for _, subscription in ipairs({admissions, replies, commands}) do process.unlisten(subscription) end
end
function M.main()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local statuses = assert(process.listen("bee.client.status", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local host = tostring(assert(process.with_options({}):with_scope(security.new_scope(policies))
        :with_context({["bee.host_owner"] = owner}):spawn_monitored("bee.workspace:host", "bee:workers", owner)))
    local started = assert(ready:receive())
    assert(started:from() == host)
    local boot: unknown = started:payload():data()
    if type(boot) ~= "table" then error("Invalid host boot") end
    local workspace_id = contract.workspace_id(boot.workspace_id)
    if not workspace_id then error("Invalid workspace ID") end
    local policy, policy_error = security.policy("bee.attachment_probe:client_policy")
    if not policy then error(tostring(policy_error)) end
    local scope = security.new_scope({policy})
    local function status(pid: string, phase: string): View?
        local message = assert(statuses:receive())
        assert(message:from() == pid)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.phase ~= phase then error("Unexpected client phase") end
        local value = data.view
        if value == nil then return nil end
        if type(value) ~= "table" or type(value.id) ~= "string" or type(value.instance_id) ~= "string" or type(value.native_pid) ~= "string" then error("Invalid view state") end
        return {id = value.id, instance_id = value.instance_id, native_pid = value.native_pid}
    end
    local function result(id: string, recipient: string, expected: string)
        local message = assert(results:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        assert(type(data) == "table" and data.request_id == id and data.recipient == recipient and data.error_code == expected)
    end
    local function admit(id: string, pid: string, allowed: boolean, expected: string)
        assert(process.send(host, "bee.host.client", {version = 1, request_id = id, op = "admit", workspace_id = workspace_id,
            recipient = pid, permissions = {open = allowed, close = false, control = allowed}}))
        result(id, pid, expected)
    end
    local function detach(id: string, pid: string)
        assert(process.send(host, "bee.host.client", {version = 1, request_id = id, op = "detach", workspace_id = workspace_id, recipient = pid}))
        result(id, pid, "")
    end
    local first = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.attachment_probe:client", "bee:workers", owner, host, workspace_id, "A")))
    status(first, "ready")
    admit("first", first, true, "")
    local first_view = status(first, "opened")
    if not first_view then error("Missing first view") end
    local second = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.attachment_probe:client", "bee:workers", owner, host, workspace_id, "B")))
    status(second, "ready")
    admit("second", second, true, "")
    local second_view = status(second, "opened")
    if not second_view then error("Missing second view") end
    assert(first_view.id ~= second_view.id and first_view.native_pid ~= second_view.native_pid, "Client request IDs collided")
    admit("cannot-replace", first, false, "busy")
    detach("detach-first", first)
    assert(process.send(first, "bee.client.command", "stale")); status(first, "stale")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    admit("readmit-first", first, false, "")
    assert(process.send(first, "bee.client.command", "readmit")); status(first, "denied")
    assert(process.send(second, "bee.client.command", "exit"))
    result("", second, "")
    detach("detach-again", first)
    assert(process.send(first, "bee.client.command", "exit"))
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local value = decode.reply(message:payload():data())
            if value and value.request_id == id and value.op == op then return value end
        end
        error("Missing supervisor reply")
    end
    for index, state in ipairs({first_view, second_view}) do
        local id = "inspect-" .. tostring(index)
        assert(process.send(host, "bee.app.request", {version = 1, request_id = id, op = "bind", workspace_id = workspace_id,
            id = state.id, instance_id = state.instance_id, recipient = owner}))
        local mounted = reply(id, "attached")
        assert(mounted.error_code == "" and reply(id, "bind").error_code == "")
        local view, err = tty.attach(mounted.mount)
        if not view then error(tostring(err)) end
        command(view, "printf 'BEE_RETAINED_%s_%s\\n' \"$bee_client\" \"$$\"")
        wait_for(view, "BEE_RETAINED_" .. (index == 1 and "A" or "B") .. "_" .. state.native_pid)
        view:close()
    end
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "stop", op = "shutdown", workspace_id = workspace_id}))
    assert(reply("stop", "shutdown").error_code == "")
    for _, subscription in ipairs({ready, results, statuses, replies}) do process.unlisten(subscription) end
end
return M
