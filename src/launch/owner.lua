-- MIT. Owns the retained workspace supervisor for the native owner invocation.
local process = require("process")
local ctx = require("ctx")
local channel = require("channel")
local security = require("security")
local time = require("time")
local logger = require("logger")
local io = require("io")
local system = require("system")
local retained = require("retained")
local ownership = require("ownership")
local registry = require("registry")
local decode = require("decode")
local workspaces = require("workspaces")
local command_stop = require("command_stop")
local handoff = require("owner_handoff")
local uuid = require("uuid")

-- The terminal.host command retains the route and supervisor. This ordinary
-- process receives definition invalidation and can be replaced under that
-- command without releasing a desktop viewport.
local function controller(owner: string, checkpoint: unknown?)
    if owner == "" or ctx.get("bee.owner_command") ~= owner then error("Untrusted owner controller") end
    assert(process.set_options({upgradable = true}))
    local state = checkpoint and handoff.decode(checkpoint, owner) or handoff.pack(owner, "", "")
    if not state then error("Incompatible retained owner checkpoint") end
    local updates = assert(process.listen("bee.owner.state", {message = true}))
    local acks = assert(process.listen("bee.owner.replace_ack", {message = true}))
    local events = assert(process.events())
    assert(process.monitor(owner))
    assert(process.send(owner, "bee.owner.controller_ready", state))
    while true do
        local selected = channel.select({updates:case_receive(), acks:case_receive(), events:case_receive()})
        if not selected.ok then error("Owner controller channel closed") end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then break end
            if event.kind == process.event.EXIT and tostring(event.from) == owner then break end
            if event.kind == process.event.OUTDATED then
                local request_id = uuid.v7()
                assert(process.send(owner, "bee.owner.replacing", {version = 1, schema = 1,
                    request_id = request_id, checkpoint = state}))
                local deadline = time.after("3s")
                while true do
                    local reply = channel.select({acks:case_receive(), deadline:case_receive()})
                    if not reply.ok or reply.channel == deadline then error("Owner replacement was not acknowledged") end
                    local message = reply.value
                    local value: unknown = message:payload():data()
                    if tostring(message:from()) == owner and type(value) == "table"
                        and value.version == 1 and value.schema == 1 and value.request_id == request_id then
                        return
                    end
                end
            end
        elseif selected.channel == updates then
            local message = selected.value
            if tostring(message:from()) == owner then
                local resumed = handoff.decode(message:payload():data(), owner)
                if resumed then state = resumed end
            end
        end
    end
    process.unlisten(updates); process.unlisten(acks)
end

local function main(controller_owner: string?, controller_checkpoint: unknown?)
    if controller_owner then return controller(controller_owner, controller_checkpoint) end
    local supervisor = ""
    local controller_pid = ""
    local registered = false
    -- This command composes the classic folder workspace.
    local workspace = workspaces.classic()
    local key = workspaces.key(workspace)
    local owner_name = key and retained.owner_name(key)
    local bridge_name = key and retained.bridge_name(key)
    if not owner_name or not bridge_name then error("Invalid retained workspace selection") end
    local ready, ready_error = process.listen("bee.retained.ready", {message = true})
    if not ready then error(tostring(ready_error)) end
    local controller_ready = assert(process.listen("bee.owner.controller_ready", {message = true}))
    local replacing = assert(process.listen("bee.owner.replacing", {message = true}))
    local stops, stops_error = command_stop.open()
    if not stops then error(stops_error) end
    local function run()
        local bridged = false
        local events, events_error = process.events()
        if not events then error(tostring(events_error)) end
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:desktop_policy", "bee.security.desktop:retained_supervisor_spawn_policy", "bee.security.desktop:retained_owner_spawn_policy",
            "bee.security.desktop:desktop_catalog_policy", "bee.security.desktop:desktop_catalog_resource_policy"}) do
            local policy, policy_error = security.policy(name)
            if not policy then error(tostring(policy_error)) end
            policies[#policies + 1] = policy
        end
        local self = tostring(process.pid())
        local checkpoint = handoff.pack(self, "", "")
        local replacing_controller = false
        local replacement_failures = 0
        local function spawn_controller(saved: unknown?)
            local started, start_error = process.with_options({}):with_context({["bee.owner_command"] = self})
                :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:owner", "bee:workers", self, saved)
            if not started then error("Start owner controller: " .. tostring(start_error)) end
            controller_pid = tostring(started)
        end
        spawn_controller(checkpoint)
        -- Exactly one composition owns the retained workspace supervisor: its
        -- workspace host registers bee.workspace.host/<workspace_id>, so a second
        -- spawn dies with "name already registered". When the host configured
        -- desktop admission, the desktop bridge composes it and forwards its
        -- readiness here.
        local service = registry.get("bee.hive_host:supervisor_service")
        bridged = ownership.desktop_bridge(service and service.data)
        if ownership.spawn_retained(bridged) then
            local started, start_error = process.with_options({}):with_context({["bee.retained_owner"] = self})
                :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:retained", "bee:workers", self, workspace)
            if not started then error(tostring(start_error)) end
            supervisor = tostring(started)
        else
            local named, name_error = process.registry.register(owner_name)
            if not named then error("Register retained owner route: " .. tostring(name_error)) end
            registered = true
            -- A bridge registered before this name may already hold readiness;
            -- one that registers later announces to this name when it is ready.
            local bridge = process.registry.lookup(bridge_name)
            if bridge then
                local sent, send_error = process.send(tostring(bridge), retained.TOPIC_OBSERVE, {version = 1})
                if not sent then error("Observe retained workspace bridge: " .. tostring(send_error)) end
            end
        end
        local announced = false
        local deadline = time.after("10s")
        while true do
            local cases = {ready:case_receive(), controller_ready:case_receive(), replacing:case_receive(),
                events:case_receive(), stops.channel:case_receive()}
            if not announced then cases[#cases + 1] = deadline:case_receive() end
            local selected = channel.select(cases)
            if not selected.ok then error("Retained owner channel closed") end
            if selected.channel == deadline then error("Retained workspace startup timed out") end
            if selected.channel == stops.channel then
                if command_stop.accept(selected.value) then return end
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then return end
                if event.kind == process.event.EXIT and tostring(event.from) == controller_pid then
                    if not replacing_controller then
                        if replacement_failures >= 2 then error("Retained owner controller replacement limit reached") end
                        replacement_failures = replacement_failures + 1
                    end
                    local resume = replacing_controller and checkpoint or nil
                    replacing_controller = false
                    spawn_controller(resume)
                    assert(process.send(controller_pid, "bee.owner.state", checkpoint))
                end
                if event.kind == process.event.EXIT and tostring(event.from) == supervisor then
                    supervisor = ""
                    error("Retained workspace supervisor exited: " .. (decode.exit_error(event.result) or "without a result"))
                end
            else
                local message = selected.value
                local sender = tostring(message:from())
                if selected.channel == replacing and sender == controller_pid then
                    local value: unknown = message:payload():data()
                    local saved = type(value) == "table" and handoff.decode(value.checkpoint, self) or nil
                    if saved and type(value) == "table" and value.version == 1 and value.schema == 1
                        and type(value.request_id) == "string" and value.request_id ~= ""
                        and (saved.workspace_id == "" or saved.workspace_id == checkpoint.workspace_id) then
                        replacing_controller = true
                        assert(process.send(controller_pid, "bee.owner.replace_ack", {version = 1, schema = 1,
                            request_id = value.request_id}))
                    end
                elseif selected.channel == controller_ready and sender == controller_pid then
                    local resumed = handoff.decode(message:payload():data(), self)
                    if not resumed then error("Owner controller did not validate its checkpoint") end
                    assert(process.send(controller_pid, "bee.owner.state", checkpoint))
                    if bridged and announced then
                        local bridge = process.registry.lookup(bridge_name)
                        if bridge then process.send(tostring(bridge), retained.TOPIC_OBSERVE, {version = 1}) end
                    end
                else
                    local announcer = supervisor
                    if bridged then
                        local bridge = process.registry.lookup(bridge_name)
                        announcer = bridge and tostring(bridge) or ""
                    end
                    if announcer ~= "" and sender == announcer and not announced then
                        local value = retained.ready(message:payload():data())
                        if not value then error("Invalid retained workspace readiness") end
                        announced = true
                        local node = system.node.id()
                        local seed = system.node.addr()
                        if not node or node == "" or not seed or seed == "" then
                            node, seed = "local", "-"
                        end
                        logger:info("Bee retained workspace ready", {workspace_id = value.workspace_id, desktop_id = value.desktop_id})
                        checkpoint = handoff.pack(self, value.workspace_id, value.desktop_id)
                        assert(process.send(controller_pid, "bee.owner.state", checkpoint))
                        assert(io.print("BEE_RETAINED_OWNER_READY " .. node .. " " .. seed .. " " .. self .. " " .. value.workspace_id .. " " .. value.desktop_id))
                    end
                end
            end
        end
    end
    local ok, err = pcall(run)
    if supervisor ~= "" then process.terminate(supervisor) end
    if controller_pid ~= "" then process.terminate(controller_pid) end
    if registered then process.registry.unregister(owner_name) end
    command_stop.close(stops)
    process.unlisten(ready)
    process.unlisten(controller_ready); process.unlisten(replacing)
    if not ok then error(err) end
end

return {main = main}
