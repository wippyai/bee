local process = require("process")
local system = require("system")
local M = {}
local function retire(runner: string?, cancel: boolean)
    if not runner then return end
    local events = assert(process.events())
    process.unmonitor(runner)
    local monitored, monitor_error = process.monitor(runner)
    if not monitored then
        assert(tostring(monitor_error) == "pid not registered", tostring(monitor_error))
        return
    end
    if cancel then
        local cancelled, cancel_error = process.cancel(runner, "fixture complete")
        assert(cancelled or tostring(cancel_error) == "pid not registered", tostring(cancel_error))
    end
    while true do
        local event = assert((events:receive()))
        assert(event.kind ~= process.event.CANCEL, "runner retirement cancelled")
        if event.kind == process.event.EXIT and tostring(event.from) == runner then break end
    end
    process.unmonitor(runner)
end
function M.join(runner: string?) retire(runner, false) end
function M.cancel(runner: string?) retire(runner, true) end

function M.owned(host: string, cancelled: {[string]: boolean}, joined: {[string]: boolean}): () -> ()
    local before: {[string]: boolean} = {}
    for _, actor in ipairs(assert(system.hosts.processes(host))) do before[actor.pid] = true end
    return function()
        local actors = assert(system.hosts.processes(host))
        for _, actor in ipairs(actors) do
            if not before[actor.pid] and cancelled[actor.source] then M.cancel(actor.pid) end
        end
        for _, actor in ipairs(actors) do
            if not before[actor.pid] and joined[actor.source] then M.join(actor.pid) end
        end
    end
end
function M.native(): () -> ()
    return M.owned("bee:workers", {["bee.placement.native.service:runner"] = true}, {["bee.placement.native.service:startup"] = true})
end
return M
