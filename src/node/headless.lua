-- MIT. bee node: runs this folder's node without a display until cancelled.
-- Displays reach it with bee or bee client from the same folder.
local io = require("io")
local system = require("system")
local process = require("process")
local channel = require("channel")

local function main(): integer
    local node = system.node.id() or "?"
    io.print("bee node " .. node .. " is running; open displays with bee in this folder, stop with Ctrl+C")
    local lifecycle = assert(process.events())
    while true do
        local selected = channel.select({lifecycle:case_receive()})
        if not selected.ok or selected.value.kind == process.event.CANCEL then return 0 end
    end
end

return {main = main}
