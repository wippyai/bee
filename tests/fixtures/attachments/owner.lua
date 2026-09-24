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
local terminal_probe = require("terminal_probe")
local observation_probe = require("observation_probe")
local logger = require("logger")
local host_probe = require("host_probe")
local clients_probe = require("clients_probe")
local function run_probe(mode: string?)
    if mode == "clients" or mode == "clients-commit" then
        local ok, err = pcall(clients_probe.main, mode == "clients-commit")
        if not ok then logger:error("Client admission probe failed", {error = tostring(err)}); error(err) end
        return
    end
    if mode == "host" or mode == "host-manual" then
        local ok, err = pcall(mode == "host-manual" and host_probe.manual or host_probe.main)
        if not ok then logger:error("Host probe failed", {error = tostring(err)}); error(err) end
        return
    end
    if mode == "observation" then
        local ok, err = pcall(observation_probe.main)
        if not ok then logger:error("Observation probe failed", {error = tostring(err)}); error(err) end
        return
    end
    if mode == "terminal" then return terminal_probe.main() end
    -- Deliberately no physical tty.start, surface or input listener.
    local owner = tostring(process.pid())
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local database = assert(store.open(nil, {root_ref = "bee:workspace_root", subpath = ""}))
    local workspace_id = assert(database:identity())
    local broker_policy, policy_error = security.policy("bee:broker_policy")
    if policy_error then error(tostring(policy_error)) end
    local boundary, boundary_error = security.policy("bee:core_spawn_boundary")
    if boundary_error then error(tostring(boundary_error)) end
    local naming_policy, naming_error = security.policy("bee.attachment_probe:naming_policy")
    if naming_error then error(tostring(naming_error)) end
    local scope = security.new_scope({broker_policy, boundary, naming_policy})
    local broker = tostring(assert(process.with_options({}):with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace_id})
        :with_scope(scope):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    -- The catalog is the owner's startup signal. Do not race name registration
    -- by treating successful spawn as service readiness.
    local ready = assert(catalogs:receive())
    assert(ready:from() == broker)
    local endpoint = "bee.attachment_probe.host"
    assert(process.registry.lookup(endpoint) == broker)
    local saved = false
    local function commit(data: unknown)
        local record = recovery.record(data)
        if not record or type(data) ~= "table" or data.workspace_id ~= workspace_id or type(data.request_id) ~= "string" then
            error("Invalid checkpoint")
        end
        assert(database:write(assert(json.encode({version = 1, desktop = {
            scene = model.new(80, 24), tabs = {}, preferences = appearance.defaults()}, applications = {record}}))))
        saved = true
        assert(process.send(endpoint, "bee.application.persisted", {version = 1, request_id = data.request_id, error_code = "", error = ""}))
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
        assert(process.send(endpoint, "bee.app.request", {version = 1, request_id = id, op = "bind", workspace_id = workspace_id, recipient = recipient}))
    end
    if mode == "failed-open" then
        bind("initial", "not-a-process")
        assert(wait_reply("initial", "bind").error_code == "")
    end
    assert(process.send(endpoint, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = workspace_id, definition_id = "bee.attachment_probe:app"}))
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
    bind("refused", owner)
    local refused = wait_reply("refused", "attached")
    assert(refused.error_code == "revoke_failed" and refused.mount == "", "Failed revoke issued a replacement")
    assert(wait_reply("refused", "bind").error_code == "revoke_failed")
    assert(table.concat(view:snapshot().rows) == first, "Failed revoke discarded the previous grant")
    bind("detach", "")
    assert(wait_reply("detach", "bind").error_code == "")
    local stale_frame, observation_error = view:snapshot()
    assert(not stale_frame and observation_error, "Detached mount retained observation")
    local sent, input_error = view:send({type = "key", key = "x", key_type = "runes", action = "press"})
    assert(not sent and input_error, "Detached mount retained input")
    local resized, resize_error = view:resize(40, 12)
    assert(not resized and resize_error, "Detached mount retained resize")
    local stale_attach, attach_error = tty.attach(attached.mount)
    assert(not stale_attach and attach_error, "Revoked mount could be attached again")
    view:close()
    bind("second", owner)
    local rebound = wait_reply("second", "attached")
    assert(rebound.instance_id == opened.instance_id and rebound.mount ~= attached.mount)
    local second = assert(tty.attach(rebound.mount))
    assert(table.concat(second:snapshot().rows) == first, "Attachment loss restarted the producer")
    wait_reply("second", "bind")
    second:close()
    assert(process.send(endpoint, "bee.app.request", {version = 1, request_id = "stop", op = "shutdown", workspace_id = workspace_id}))
    assert(wait_reply("stop", "shutdown").error_code == "")
    database:close()
    process.terminate(broker)
    process.unlisten(replies)
    process.unlisten(catalogs)
    process.unlisten(checkpoints)
end
local function main(mode: string?)
    run_probe(mode)
    logger:info("BEE_ATTACHMENT_COMPLETE:" .. tostring(mode or "detached"))
end
return {main = main}
