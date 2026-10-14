-- MIT. The fixture application: a bee.app entry the node admits so the test
-- runner has an application whose authority its tests run under.
local process = require("process")

local function main()
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end

return {main = main}
