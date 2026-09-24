-- MIT. Owns the retained workspace supervisor for the native owner invocation.
local process = require("process")
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

local function main()
    local supervisor = ""
    local registered = false
    -- This command composes the classic folder workspace.
    local workspace = workspaces.classic()
    local key = workspaces.key(workspace)
    local owner_name = key and retained.owner_name(key)
    local bridge_name = key and retained.bridge_name(key)
    if not owner_name or not bridge_name then error("Invalid retained workspace selection") end
    local ready, ready_error = process.listen("bee.retained.ready", {message = true})
    if not ready then error(tostring(ready_error)) end
    local function run()
        local bridged = false
        local events, events_error = process.events()
        if not events then error(tostring(events_error)) end
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee:host_policy", "bee:desktop_policy", "bee:retained_supervisor_spawn_policy",
            "bee:desktop_catalog_policy", "bee:desktop_catalog_resource_policy"}) do
            local policy, policy_error = security.policy(name)
            if not policy then error(tostring(policy_error)) end
            policies[#policies + 1] = policy
        end
        local self = tostring(process.pid())
        -- Exactly one composition owns the retained workspace supervisor: its
        -- workspace host registers bee.workspace.host/<workspace_id>, so a second
        -- spawn dies with "name already registered". When the host configured
        -- desktop admission, the desktop bridge composes it and forwards its
        -- readiness here.
        local service = registry.get("bee.hive.host:supervisor_service")
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
            local cases = {ready:case_receive(), events:case_receive()}
            if not announced then cases[#cases + 1] = deadline:case_receive() end
            local selected = channel.select(cases)
            if not selected.ok then error("Retained owner channel closed") end
            if selected.channel == deadline then error("Retained workspace startup timed out") end
            if selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then return end
                if event.kind == process.event.EXIT and tostring(event.from) == supervisor then
                    supervisor = ""
                    error("Retained workspace supervisor exited: " .. (decode.exit_error(event.result) or "without a result"))
                end
            else
                local message = selected.value
                local sender = tostring(message:from())
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
                    assert(io.print("BEE_RETAINED_OWNER_READY " .. node .. " " .. seed .. " " .. self .. " " .. value.workspace_id .. " " .. value.desktop_id))
                end
            end
        end
    end
    local ok, err = pcall(run)
    if supervisor ~= "" then process.terminate(supervisor) end
    if registered then process.registry.unregister(owner_name) end
    process.unlisten(ready)
    if not ok then error(err) end
end

return {main = main}
