-- SPDX-License-Identifier: MIT
-- Supervised background owner worker that applies approved Hub installation requests.
local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local installation = require("installation")

local function main()
    local lifecycle = assert(process.events())
    local wait_ms = 100
    while true do
        local called, processed, drain_error = pcall(installation.drain_approved)
        if called and not drain_error then
            wait_ms = 100
        else
            local cause = drain_error
            if not called then cause = processed end
            logger:warn("Gateway installation drain failed", {cause = tostring(cause)})
            wait_ms = math.min(math.max(wait_ms * 2, 1000), 30000)
        end
        local tick = time.after(tostring(wait_ms) .. "ms")
        local selected = channel.select({lifecycle:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == lifecycle then return end
    end
end

return {main = main}
