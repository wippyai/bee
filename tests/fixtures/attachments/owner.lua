local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local tty = require("tty")
local json = require("json")
local decode = require("decode")
local model = require("model")
local appearance = require("appearance")
local recovery = require("recovery")
local store = require("store")
local function main(mode: string?)
    -- Deliberately no physical tty.start, surface or input listener.
    local owner = tostring(process.pid())
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local database = assert(store.open())
    local workspace_id = assert(database:identity())
    local broker_policy, policy_error = security.policy("bee:broker_policy")
    if policy_error then error(tostring(policy_error)) end
    local boundary, boundary_error = security.policy("bee:core_spawn_boundary")
    if boundary_error then error(tostring(boundary_error)) end
    local scope = security.new_scope({broker_policy, boundary})
    local broker = tostring(assert(process.with_options({}):with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace_id})
        :with_scope(scope):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    local saved = false
    local function commit(data: unknown)
        local record = recovery.record(data)
        if not record or type(data) ~= "table" or data.workspace_id ~= workspace_id or type(data.request_id) ~= "string" then
            error("Invalid checkpoint")
        end
        assert(database:write(assert(json.encode({version = 1, desktop = {
            scene = model.new(80, 24), tabs = {}, preferences = appearance.defaults()}, applications = {record}}))))
        saved = true
        assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = data.request_id, error_code = "", error = ""}))
    end
    local function wait_reply(request_id: string, op: string): decode.Reply
        while true do
            local selected = channel.select({replies:case_receive(), checkpoints:case_receive()})
            assert(selected.ok)
            local message = selected.value
            assert(message:from() == broker)
            if selected.channel == checkpoints then
                commit(message:payload():data())
            else
                local reply = decode.reply(message:payload():data())
                if not reply then error("Invalid broker reply") end
                assert(decode.belongs(reply, workspace_id))
                assert(reply.op ~= "closed", "Detached producer stopped")
                if reply.request_id == request_id and reply.op == op then return reply end
            end
        end
        error("Reply channel closed")
    end
    local function bind(id: string, recipient: string)
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = id, op = "bind", workspace_id = workspace_id, recipient = recipient}))
    end
    if mode == "failed-open" then
        bind("initial", "not-a-process")
        assert(wait_reply("initial", "bind").error_code == "")
    end
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = workspace_id, definition_id = "bee.attachment_probe:app"}))
    local opened = wait_reply("open", "open")
    assert(opened.error_code == "" and opened.mount == "", "Headless open required an attachment")
    if mode == "failed-open" then
        assert(wait_reply("open", "attached").error_code == "attachment_failed", "Missing initial mount failure")
    end
    if not saved then
        local message = assert(checkpoints:receive())
        assert(message:from() == broker)
        commit(message:payload():data())
    end
    assert(saved and database:read() ~= nil, "Detached checkpoint was not committed")
    time.sleep("4s")
    bind("invalid", "not-a-process")
    local denied = wait_reply("invalid", "attached")
    assert(denied.error_code == "attachment_failed" and denied.id == opened.id)
    assert(wait_reply("invalid", "bind").error_code == "attachment_failed")
    bind("first", owner)
    local attached = wait_reply("first", "attached")
    assert(attached.error_code == "" and attached.instance_id == opened.instance_id)
    local view = assert(tty.attach(attached.mount))
    local first = table.concat(view:snapshot().rows)
    assert(first:find("SAVED ", 1, true) ~= nil, "Checkpoint receipt did not reach the producer")
    wait_reply("first", "bind")
    view:close()
    bind("detach", "")
    wait_reply("detach", "bind")
    bind("second", owner)
    local rebound = wait_reply("second", "attached")
    assert(rebound.instance_id == opened.instance_id and rebound.mount ~= attached.mount)
    local second = assert(tty.attach(rebound.mount))
    assert(table.concat(second:snapshot().rows) == first, "Attachment loss restarted the producer")
    wait_reply("second", "bind")
    second:close()
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "stop", op = "shutdown", workspace_id = workspace_id}))
    assert(wait_reply("stop", "shutdown").error_code == "")
    database:close()
    process.terminate(broker)
    process.unlisten(replies)
    process.unlisten(checkpoints)
end
return {main = main}
