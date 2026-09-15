-- MIT. Restore only destination intents already authorized before restart.
local process = require("process")
local service = require("service")

local function main()
    local recovered, recovery_error = service.recover_all()
    if not recovered then error("recover destination applications: " .. tostring(recovery_error)) end
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end

return {main = main}
