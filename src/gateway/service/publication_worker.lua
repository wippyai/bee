-- SPDX-License-Identifier: MIT
-- Supervised background owner worker that uploads approved Hub publication requests.
local logger = require("logger")
local worker = require("worker")
local publish = require("publish")
local approval_service = require("approval_service")

local function drain(): boolean
    local called, _, drain_error = pcall(publish.drain_approved)
    if called and not drain_error then return true end
    local cause: unknown = drain_error
    if not called then cause = _ end
    logger:error("Gateway publication drain failed", {cause = tostring(cause)})
    return false
end

local function main()
    worker.run({name = approval_service.PUBLICATION_WORKER_NAME, wake = approval_service.TOPIC_WAKE, pass = drain})
end

return {main = main}
