-- MIT. A recipient that holds an attachment until it is stopped.
local process = require("process")
local channel = require("channel")
local function main()
    local events = assert(process.events())
    while true do
        local selected = channel.select({events:case_receive()})
        if not selected.ok or selected.value.kind == process.event.CANCEL then return end
    end
end
return {main = main}
