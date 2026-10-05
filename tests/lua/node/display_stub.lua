-- MIT. A second display for owner tests: it runs each node operation a
-- message asks for and replies with the result, so the owner sees a caller
-- other than the test.
local process = require("process")
local channel = require("channel")
local system = require("system")
local client = require("client")

local function main()
    local lifecycle = assert(process.events())
    local inbox = assert(process.listen("request", {message = true}))
    while true do
        local selected = channel.select({inbox:case_receive(), lifecycle:case_receive()})
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then return end
        else
            local message = selected.value :: process.Message
            local request = message:payload():data() :: {op: string, args: {[string]: unknown}}
            local value, err = client.call(assert(system.node.id()), request.op, request.args)
            process.send(tostring(message:from()), "display_stub.reply", {value = value, error = err})
        end
    end
end

return {main = main}
