-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local demand = require("demand")
local protocol = require("protocol")
local bounds = require("bounds")
local NAME = "bee.test.transaction.owner"
local function main()
    assert(process.registry.register(NAME))
    local wakes = assert(process.listen(demand.WAKE, {message = true}))
    local lifecycle = assert(process.events())
    assert(demand.ready(NAME))
    while true do
        local selected = channel.select({wakes:case_receive(), lifecycle:case_receive()})
        if not selected.ok then return end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then return end
        else
            local message = selected.value
            local supervisor = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
            assert(tostring(message:from()) == tostring(supervisor))
            local envelope = assert(bounds.object(message:payload():data()))
            local generation = assert(bounds.integer(envelope.generation))
            for _, raw in ipairs(assert(bounds.array(envelope.requests, 64))) do
                local data = assert(bounds.object(assert(bounds.object(raw)).data))
                local request = assert(protocol.forwarded(tostring(supervisor), data.hive))
                assert(request.op == "serve")
                assert(process.send(request.caller, request.reply_topic, protocol.ok({request_id = request.args.request_id})))
            end
            assert(demand.quiet(NAME, generation))
        end
    end
end
return {main = main}
