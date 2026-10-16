local process = require("process")
local events = require("events")
local system = require("system")
local channel = require("channel")
local uuid = require("uuid")
local demand = require("demand")
local processes = require("processes")
local M = {}
function M.stopped(service: string, owner: string, subscription: events.Subscription?)
    local updates = subscription or assert(events.subscribe("supervisor", "service.update"))
    local lifecycle = assert(process.events())
    local name = "bee.test.owner.stopped." .. owner
    local topic = name .. "." .. assert(uuid.v7())
    local replies = assert(process.listen(topic, {message = true}))
    assert(process.registry.register(name))
    local supervisor = tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)))
    local monitored: string? = nil
    local ok, failure = pcall(function()
        assert(process.send(supervisor, demand.TOPIC, {action = "bee.test.owner.stopped", name = owner, topic = topic}))
        local acknowledged = false
        while true do
            local state = assert(system.supervisor.state(service))
            local holder = process.registry.lookup(owner, process.registry.LOCAL)
            local dormant = (state.status == "unknown" and state.desired == "unknown")
                or (state.desired == "stopped" and (state.status == "stopped" or state.status == "exited"))
            if dormant and not holder and acknowledged then break end
            if holder and tostring(holder) ~= monitored then
                if monitored then process.unmonitor(monitored) end
                monitored = tostring(holder)
                local observed, problem = process.monitor(monitored)
                assert(observed or processes.vanished(problem), tostring(problem))
            end
            local selected = channel.select({updates:channel():case_receive(), lifecycle:case_receive(), replies:case_receive()})
            assert(selected.ok, owner .. " did not retire: " .. state.status .. "/" .. state.desired)
            if selected.channel == lifecycle then assert(selected.value.kind ~= process.event.CANCEL, "owner observation cancelled") end
            if selected.channel == replies then
                assert(tostring(selected.value:from()) == supervisor, "owner receipt sender")
                acknowledged = true
            end
        end
    end)
    if monitored then process.unmonitor(monitored) end
    process.unlisten(replies)
    process.registry.unregister(name)
    if not subscription then updates:close() end
    assert(ok, failure)
end
return M
