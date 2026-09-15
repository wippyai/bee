-- MIT. Keeps the native owner invocation alive without starting another host.
local process = require("process")

local function main()
    local events, err = process.events()
    if not events then error(tostring(err)) end
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return 0 end
    end
end

return {main = main}
