-- MIT. Test-only stand-in for a retained display: it relays the switch
-- answers its supervisor sends it to the test.
local process = require("process")
local channel = require("channel")
local function main(test: string)
    local answers = assert(process.listen("bee.retained.switched", {message = true}))
    local events = assert(process.events())
    while true do
        local selected = channel.select({answers:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        else
            process.send(test, "bee.test.switch.relayed", selected.value:payload():data())
        end
    end
    process.unlisten(answers)
end
return {main = main}
