-- MIT. The module's owner process: establishes this runtime's incarnation
-- at start and stays until the host stops it. It sweeps pending notices at
-- start and on a tick, so a notice whose ending record committed without a
-- settling pass is still delivered. It holds no other state.
local process = require("process")
local time = require("time")
local notices = require("notices")
local boundary = require("boundary")
local channel = require("channel")
local SWEEP_INTERVAL = "5s"
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
    local function sweep()
        local store = database.open(resource :: string)
        if not store then return end
        local woken = notices.fire(store, nil)
        store:release()
        for _, thread_id in ipairs(woken or {}) do boundary.wake(thread_id) end
    end
    sweep()
    local events = assert(process.events())
    local ticker = time.ticker(SWEEP_INTERVAL)
    while true do
        local selected = channel.select({events:case_receive(), ticker:channel():case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return end
        else
            sweep()
        end
    end
end
return {main = main}
