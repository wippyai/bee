-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local runtime = require("runtime")
local recovery = require("recovery")
local function main(controller: string)
    local lifecycle = assert(process.events())
    local stopped: channel.Channel<boolean> = channel.new(1)
    local cancelled = false
    local function active(): boolean return not cancelled end
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
    runtime.reset()
    runtime.controller = controller
    recovery.recover(active)
    lifecycle:close()
    assert(process.send(controller, "bee.test.recovery.done", {settled = runtime.settled, announced = runtime.announced, released = runtime.released}))
end
return {main = main}
