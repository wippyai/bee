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

local function main()
    local supervisor = ""
    local ready, ready_error = process.listen("bee.retained.ready", {message = true})
    if not ready then error(tostring(ready_error)) end
    local function run()
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
        -- spawn dies with "name already registered". When the host configured a
        -- desktop bridge, the bridge already composed it and this route only
        -- reports its readiness.
        local bridge = registry.get("bee.hive.host:supervisor_service")
        local desktop_host = bridge ~= nil and bridge.data ~= nil
        if ownership.spawn_retained(desktop_host) then
            local started, start_error = process.with_options({}):with_context({["bee.retained_owner"] = self})
                :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:retained", "bee:workers", self)
            if not started then error(tostring(start_error)) end
            supervisor = tostring(started)
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
                if tostring(message:from()) == supervisor and not announced then
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
    process.unlisten(ready)
    if not ok then error(err) end
end

return {main = main}
