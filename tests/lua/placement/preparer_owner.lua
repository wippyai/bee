-- MIT. Owns a fixture preparation until the test releases its actor.
local process = require("process")
return {main = function()
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if event.kind == process.event.CANCEL then return end
    end
end}
