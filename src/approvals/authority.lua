-- MIT. The authority process: establishes the approval authority's
-- incarnation for this node before any request is served under it, holds
-- the authority name while it lives, and does nothing else. A restart is a
-- new incarnation; consumers that observed the old one revalidate.
local process = require("process")
local service = require("service")
local function main()
    local registered, register_error = process.registry.register(service.AUTHORITY_NAME)
    if not registered then error("register approval authority: " .. tostring(register_error)) end
    local db, open_error = service.open()
    if not db then error("open approval store: " .. tostring(open_error)) end
    local _, establish_error = service.establish(db)
    db:release()
    if establish_error then error("establish authority incarnation: " .. establish_error) end
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end
return {main = main}
