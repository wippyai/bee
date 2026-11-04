-- MIT. Follows a process's lifecycle events: active reports whether the process
-- is still running and stopped delivers once when it is cancelled.
local channel = require("channel")
local process = require("process")

local M = {}

function M.follow(lifecycle: channel.Channel<any>): (() -> boolean, channel.Channel<boolean>)
    local stopped: channel.Channel<boolean> = channel.new(1)
    local cancelled = false
    coroutine.spawn(function()
        while true do
            local selected = channel.select({lifecycle:case_receive()})
            if not selected.ok or selected.value.kind == process.event.CANCEL then
                cancelled = true
                stopped:send(true)
                return
            end
        end
    end)
    return function(): boolean return not cancelled end, stopped
end

return M
