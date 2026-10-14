-- MIT. A routed test service: registers its name, tells the supervisor it is
-- ready and answers one forwarded request.
local process = require("process")
local channel = require("channel")
local protocol = require("protocol")

local function main()
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    assert(process.registry.register("bee.tests.parked"))
    assert(protocol.ready("bee.tests.parked"))
    local selected = channel.select({requests:case_receive()})
    local request = protocol.forwarded(tostring(selected.value:from()), selected.value:payload():data())
    if request then process.send(request.caller, request.reply_topic, protocol.ok({op = request.op, label = request.args.label})) end
end

return {main = main}
