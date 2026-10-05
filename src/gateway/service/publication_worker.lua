-- SPDX-License-Identifier: MIT
-- Supervised background owner worker that uploads approved Hub publication requests.
local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local publish = require("publish")
local approval_service = require("approval_service")
type Channel = channel.Channel

local function main()
    local lifecycle = assert(process.events())
    local wakes = assert(process.listen(approval_service.TOPIC_WAKE, {message = true}))
    local registered, register_error = process.registry.register(approval_service.PUBLICATION_WORKER_NAME)
    if not registered then error("register publication effect worker: " .. tostring(register_error)) end
    local retry_ms = 1000
    local retrying = false
    local function drain(): boolean
        local called, _, drain_error = pcall(publish.drain_approved)
        if called and not drain_error then return true end
        local cause: unknown = drain_error
        if not called then cause = _ end
        logger:error("Gateway publication drain failed", {cause = tostring(cause)})
        return false
    end
    retrying = not drain()
    while true do
        local cases = {lifecycle:case_receive(), wakes:case_receive()}
        local retry: Channel<time.Time>? = nil
        if retrying then
            retry = time.after(tostring(retry_ms) .. "ms")
            cases[#cases + 1] = retry:case_receive()
        end
        local selected = channel.select(cases)
        if not selected.ok then return end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then return end
        else
            retrying = not drain()
            if retrying then retry_ms = math.min(retry_ms * 2, 30000)
            else retry_ms = 1000 end
        end
    end
end

return {main = main}
