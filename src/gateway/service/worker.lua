-- SPDX-License-Identifier: MIT
-- Supervised background owner worker that applies approved Hub installation requests.
local logger = require("logger")
local worker = require("worker")
local installation = require("installation")
local approval_service = require("approval_service")

local function drain(): boolean
    local called, _, drain_error = pcall(installation.drain_approved)
    if called and not drain_error then return true end
    local cause: unknown = drain_error
    if not called then cause = _ end
    logger:error("Gateway installation drain failed", {cause = tostring(cause)})
    return false
end

local function main()
    worker.run({name = "bee.approvals.installation_effect_worker", wake = approval_service.TOPIC_WAKE, pass = drain})
end

return {main = main}
