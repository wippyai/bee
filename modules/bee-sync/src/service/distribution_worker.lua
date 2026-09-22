-- MIT. Bounded background distribution for configured immutable Sync feeds.
local process = require("process")
local channel = require("channel")
local time = require("time")
local distributor = require("distributor")

local function main()
    local lifecycle = assert(process.events())
    while true do
        distributor.run_once()
        local tick = time.after("5s")
        local selected = channel.select({lifecycle:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == lifecycle then return end
    end
end

return {main = main}
