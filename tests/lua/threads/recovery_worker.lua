-- SPDX-License-Identifier: MIT
local process = require("process")
local cancellation = require("cancellation")
local recovery = require("recovery")
local runtime = require("runtime")

local function main(controller: string)
    local lifecycle = assert(process.events())
    local active = cancellation.follow(lifecycle)
    runtime.reset()
    runtime.controller = controller
    recovery.recover(active, runtime.store)
    lifecycle:close()
    assert(process.send(controller, "bee.test.recovery.done",
        {settled = runtime.settled, announced = runtime.announced, released = runtime.released}))
end

return {main = main}
