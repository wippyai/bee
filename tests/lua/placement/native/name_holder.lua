-- MIT. Holds a process name for a test until it is cancelled.
local process = require("process")
return {main = function(name: string, reporter: string)
    local events = assert(process.events())
    local registered = process.registry.register(name)
    process.send(reporter, "bee.test.name.held", {ok = registered == true})
    if not registered then return end
    while true do
        local event = events:receive()
        if event.kind == process.event.CANCEL then return end
    end
end}
