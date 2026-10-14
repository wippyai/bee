-- MIT. A live process that stands in for a desktop client or renderer until
-- the test cancels it. Test support only.
local process = require("process")
return {main = function()
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end}
