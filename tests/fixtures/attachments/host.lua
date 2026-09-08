-- MIT. Exercise the actual stable workspace host without a desktop or physical TTY.
local process = require("process")
local security = require("security")
local tty = require("tty")
local contract = require("contract")
local decode = require("decode")
local recovery = require("recovery")
local M = {}
function M.guest(owner: string, host: string, workspace_id: string)
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "forged", op = "open",
        workspace_id = workspace_id, definition_id = "bee.attachment_probe:app"}))
    assert(process.send(owner, "bee.host.guest_sent", {}))
end
function M.main()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.host.checkpoint", {message = true}))
    local restores = assert(process.listen("bee.host.restore_result", {message = true}))
    local events = assert(process.events())
    local guest_sent = assert(process.listen("bee.host.guest_sent", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local scope = security.new_scope(policies)
    local function start(expected_records: integer): (string, string)
        local host = tostring(assert(process.with_options({}):with_scope(scope):with_context({["bee.host_owner"] = owner})
            :spawn_monitored("bee.host:main", "bee:workers", owner)))
        local message = assert(ready:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.version ~= 1 then error("Invalid host readiness") end
        local saved: unknown = data.saved
        if type(saved) ~= "table" or type(saved.applications) ~= "table" then error("Missing saved application snapshot") end
        assert(#saved.applications == expected_records, "Unexpected persisted application membership")
        local workspace_id = contract.workspace_id(data.workspace_id)
        if not workspace_id then error("Missing host workspace identity") end
        return host, workspace_id
    end
    local host, workspace_id = start(0)
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local result = decode.reply(message:payload():data())
            if not result then error("Invalid host reply") end
            assert(result.request_id ~= "forged", "Host accepted a non-supervisor request")
            assert(decode.belongs(result, workspace_id))
            if result.request_id == id and result.op == op then return result end
        end
        error("Host reply channel closed")
    end
    local function request(id: string, op: string, recipient: string?)
        assert(process.send(host, "bee.app.request", {version = 1, request_id = id, op = op,
            workspace_id = workspace_id, definition_id = op == "open" and "bee.attachment_probe:app" or "",
            recipient = recipient or ""}))
    end
    local function stop(id: string)
        request(id, "shutdown")
        assert(reply(id, "shutdown").error_code == "")
        while true do
            local event = assert(events:receive())
            if event.kind == process.event.EXIT and tostring(event.from) == host then break end
        end
    end
    local guest = tostring(assert(process.with_options({}):spawn_monitored(
        "bee.attachment_probe:host_guest", "bee:workers", owner, host, workspace_id)))
    assert(guest_sent:receive():from() == guest)
    request("open", "open")
    local opened = reply("open", "open")
    assert(opened.error_code == "" and opened.mount == "")
    local committed = assert(checkpoints:receive())
    assert(committed:from() == host)
    local data: unknown = committed:payload():data()
    if type(data) ~= "table" or data.workspace_id ~= workspace_id then error("Foreign checkpoint") end
    local record = recovery.record(data.record)
    assert(record and record.instance_id == opened.instance_id)
    request("attach", "bind", owner)
    local mounted = reply("attach", "attached")
    local view, view_error = tty.attach(mounted.mount)
    if not view then error(tostring(view_error)) end
    assert(reply("attach", "bind").error_code == "")
    local frame = assert(view:snapshot())
    assert(table.concat(frame.rows):find("SAVED ", 1, true), "Host did not acknowledge committed checkpoint")
    request("detach", "bind")
    assert(reply("detach", "bind").error_code == "")
    local stale, denied = view:snapshot()
    assert(not stale and denied)
    view:close()
    stop("stop-first")
    local previous_workspace = workspace_id
    host, workspace_id = start(1)
    assert(workspace_id == previous_workspace)
    local restored_message = assert(restores:receive())
    assert(restored_message:from() == host)
    local restored = decode.reply(restored_message:payload():data())
    assert(restored and restored.error_code == "" and restored.id == opened.id and restored.instance_id == opened.instance_id)
    stop("stop-second")
    for _, subscription in ipairs({ready, replies, checkpoints, restores, guest_sent}) do process.unlisten(subscription) end
end
return M
