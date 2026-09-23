-- MIT. Two-runtime supervisor fixture; no fixture PID is accepted as a peer.
local process = require("process")
local security = require("security")
local time = require("time")
local channel = require("channel")
local io = require("io")
local system = require("system")
local types = require("types")
local client = require("client")
local funcs = require("funcs")
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local function main(remote: string)
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:hive_supervisor_policy", "bee:hive_catalog_policy", "bee:hive_exposure_policy",
        "bee:hive_dispatch_policy", "bee.hive_probe:names_policy", "bee.hive_probe:execute_policy"}) do
        local policy, policy_error = security.policy(name)
        if not policy then error("load supervisor policy " .. name .. ": " .. tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local events = assert(process.events())
    local function start(): string
        local spawned, spawn_error = process.with_options({}):with_scope(security.new_scope(policies))
            :spawn_monitored("bee.hive.supervisor:main", types.SUPERVISOR_HOST, {configured_nodes = {remote}})
        local pid = tostring(assert(spawned, tostring(spawn_error)))
        local deadline = time.now():add("5s")
        while time.now():before(deadline) do
            if client.supervisor() == pid then return pid end
            time.sleep("10ms")
        end
        error("supervisor did not register its local name")
    end
    local function stop(pid: string)
        assert(process.cancel(pid))
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({events:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("supervisor did not stop") end
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == pid then
                local result: unknown = event.result
                if type(result) == "table" and result.error then error(tostring(result.error)) end
                return
            end
        end
    end
    local supervisor = start()
    assert(io.print("BEE_HIVE_SUPERVISOR ready " .. tostring(assert(system.node.addr()))))
    while true do
        local command = tostring(assert(io.readline()))
        if command == "identity" then
            assert(io.print("BEE_HIVE_SUPERVISOR identity " .. tostring(process.pid())))
        elseif command:match("^feed%-") or command:match("^enroll%-") or command:match("^approval%-") or command == "revoke" then
            local answer, err = funcs.new():call("bee.feed_probe:handle", {command = command, remote = remote})
            if err or type(answer) ~= "string" then error("feed fixture: " .. tostring(err)) end
            assert(io.print("BEE_HIVE_SUPERVISOR " .. answer))
        elseif command == "probe" then
            local handle, open_error = client.open()
            if not handle then error(tostring(open_error)) end
            local deadline = time.now():add("30s")
            local reply: types.Reply? = nil
            while time.now():before(deadline) do
                reply = handle:call({node_id = remote, service_id = "bee.hive.telemetry"},
                    {operation_ref = "bee.hive.telemetry:presence"}, {}, {timeout = "1s"})
                if reply.ok then break end
                -- Presence is a read: a replacement can make its dispatched outcome
                -- uncertain, and retrying this read is safe. Mutations must reconcile.
                if reply.error and reply.error.code ~= "UNAVAILABLE" and reply.error.code ~= "UNCERTAIN" then error("remote call refused: " .. reply.error.code .. ": " .. reply.error.message) end
                time.sleep("100ms")
            end
            if not reply or not reply.ok then error("remote supervisor never established") end
            local value: unknown = reply.value
            if type(value) ~= "table" or value.node_id ~= remote then error("telemetry did not execute on destination") end
            local denied = handle:call({node_id = remote, service_id = "bee.hive.telemetry", resource_ref = "forbidden"},
                {operation_ref = "bee.hive.telemetry:stats"}, {}, {timeout = "3s"})
            if not denied.error or denied.error.code ~= "INVALID_ARGUMENT" then error("resource scope was not refused") end
            handle:close()
            assert(io.print("BEE_HIVE_SUPERVISOR probe_passed"))
        elseif command == "sibling" then
            local target = assert(process.registry.lookup(types.SUPERVISOR_NAME .. "/" .. remote))
            local replies = assert(process.listen(types.TOPIC_REPLY, {message = true}))
            local local_node = assert(system.node.id())
            local now = time.now()
            local input: {[string]: unknown} = {}
            local request: types.Request = {
                protocol_revision = types.REVISION, request_id = "sibling-forgery", idempotency_key = "sibling-forgery-key",
                caller_node_id = local_node, caller_incarnation = "sibling-forgery-incarnation",
                owner_ref = {node_id = remote, service_id = "bee.hive.telemetry"},
                operation_ref = "bee.hive.telemetry:stats", operation_revision = "1", input = input,
                input_digest = assert(types.digest(input)),
                principal_ref = {issuer = local_node, subject_id = tostring(process.pid())},
                principal_assertion = {method = types.ASSERTION_METHOD, audience = remote,
                    issued_at = now:utc():format(FORMAT), expires_at = now:add("5s"):utc():format(FORMAT)},
                delegation_refs = {}, deadline = now:add("5s"):utc():format(FORMAT),
            }
            assert(process.send(target, types.TOPIC_REQUEST, request))
            local deadline = time.after("3s")
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("missing sibling refusal") end
            local message = selected.value
            if tostring(message:from()) ~= target then error("wrong refusal sender") end
            local reply = types.decode_reply(message:payload():data())
            if not reply or not reply.error or reply.error.code ~= "DENIED" then error("sibling was not denied") end
            process.unlisten(replies)
            assert(io.print("BEE_HIVE_SUPERVISOR sibling_denied"))
        elseif command == "check-name" then
            -- The fixture's boot authority deliberately installs an incorrect
            -- alias. Native registration allows a foreign PID with an explicit
            -- grant; the client must still validate the returned node.
            local foreign, foreign_error = process.registry.lookup(types.SUPERVISOR_NAME .. "/" .. remote)
            if not foreign then error(tostring(foreign_error)) end
            stop(supervisor)
            supervisor = ""
            local named, register_error = process.registry.register(types.SUPERVISOR_NAME, foreign)
            if not named then error(tostring(register_error)) end
            local found, lookup_error = client.supervisor()
            local removed, name_error = process.registry.unregister(types.SUPERVISOR_NAME)
            if not removed then error(tostring(name_error)) end
            if found or lookup_error ~= "supervisor name resolves outside this node" then
                error("foreign alias was not refused; observed " .. tostring(found) .. ": " .. tostring(lookup_error))
            end
            assert(io.print("BEE_HIVE_SUPERVISOR foreign_name_denied"))
        elseif command == "restart" then
            local old = supervisor
            if supervisor ~= "" then stop(supervisor) end
            supervisor = start()
            if old == supervisor then error("restart reused PID") end
            assert(io.print("BEE_HIVE_SUPERVISOR restarted"))
        elseif command == "stop" then
            stop(supervisor)
            assert(io.print("BEE_HIVE_SUPERVISOR stopped"))
            return
        else error("unexpected command") end
    end
end
return {main = main}
