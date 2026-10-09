-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local demand = require("demand")
local bounds = require("bounds")
local function main(attempt_id: string, after: integer, id: string): unknown
    local name = "bee.placement.sweeper"
    local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
    local replies = assert(process.listen("bee.placement.preparer.reply", {message = true}))
    local events = assert(process.events())
    local sent, err = demand.dispatch(name, {request_id = id, attempt_id = attempt_id, after = after})
    if not sent then return {ok = false, error = err} end
    local owner: string? = nil
    while not owner do
        local selected = channel.select({accepted:case_receive(), events:case_receive()})
        if not selected.ok or (selected.channel == events and selected.value.kind == process.event.CANCEL) then
            return {ok = false, error = "cleanup caller cancelled"}
        end
        if selected.channel == accepted then
            local message = selected.value
            local value = bounds.object(message:payload():data())
            local supervisor = process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)
            if tostring(message:from()) == tostring(supervisor) and value and value.name == name and value.request_id == id then
                owner = bounds.id(value.pid)
            end
        end
    end
    local ended = not process.monitor(owner)
    while true do
        local selected
        if ended then selected = channel.select({replies:case_receive(), default = true})
        else selected = channel.select({replies:case_receive(), events:case_receive()}) end
        if not selected.ok then return {ok = false, error = "cleanup owner exited before acknowledgement"} end
        if selected.channel == replies then
            local message = selected.value
            local value = bounds.object(message:payload():data())
            if tostring(message:from()) == owner and value and value.request_id == id then return value end
        elseif selected.value.kind == process.event.EXIT and tostring(selected.value.from) == owner then ended = true
        elseif selected.value.kind == process.event.CANCEL or selected.value.kind == process.event.MONITOR_DOWN then
            return {ok = false, error = "cleanup ownership observation ended"}
        end
    end
end
return {main = main}
