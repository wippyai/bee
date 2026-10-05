-- MIT. A supervised service that runs until it is cancelled.
local process = require("process")
local function main()
    local events = process.events()
    while true do
        local event, ok = events:receive()
        if not ok or event.kind == process.event.CANCEL then return end
    end
end
return {main = main}
