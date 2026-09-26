-- SPDX-License-Identifier: MIT
-- Supervised background owner worker that applies approved Hub installation requests.
local process = require("process")
local channel = require("channel")
local time = require("time")
local installation = require("installation")

local function main()
    local lifecycle = assert(process.events())
    while true do
        pcall(installation.drain_approved)
        local tick = time.after("100ms")
        local selected = channel.select({lifecycle:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == lifecycle then return end
    end
end

return {main = main}
