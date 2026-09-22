-- MIT. The module's owner process: establishes this runtime's incarnation
-- at start and stays until the host stops it. It holds no other state.
local process = require("process")
local resources = require("resources")
local database = require("database")
local owner = require("owner")
local function main()
    local resource, resource_error = resources.database()
    if not resource then error(resource_error) end
    local db, open_error = database.open(resource)
    if not db then error(open_error) end
    local incarnation, establish_error = owner.establish(db)
    db:release()
    if not incarnation then error(establish_error) end
    local events = assert(process.events())
    while true do
        local event, open = events:receive()
        if not open then return end
        if event.kind == process.event.CANCEL then return end
    end
end
return {main = main}
