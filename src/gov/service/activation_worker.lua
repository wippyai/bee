-- SPDX-License-Identifier: MIT
local logger = require("logger")
local worker = require("worker")
local pass = require("pass")
local service = require("service")
local bounds = require("bounds")

local function drain(): boolean
    local retry = false
    local progressed = false
    local reconcile = true
    repeat
        progressed = false
        retry = false
        local outcomes, pass_error = pass.run(reconcile)
        reconcile = false
        if not outcomes then
            logger:error("Activation queues are unreadable", {cause = pass_error})
            return false
        end
        for _, item in ipairs(outcomes) do
            if item.ok then
                progressed = progressed or (item.phase == "settled" and item.outcome ~= "uncertain")
                logger:info(item.outcome == "applied" and "Approved activation applied" or "Activation settled",
                    {approval_id = item.approval_id, phase = item.phase, outcome = item.outcome, reason = item.message})
            else
                logger:warn(item.kind == "approved" and "Approved activation was not applied" or "Ended activation was not settled",
                    {approval_id = item.approval_id, code = item.code, reason = item.message})
                retry = retry or (item.code ~= "UNCERTAIN" and item.code ~= "CONFLICT")
            end
        end
    until not progressed or not pass.pending()
    local followed = service.follow_all()
    if not followed.ok then
        logger:error("Source following ledger is unreadable", {cause = followed.message})
        return false
    end
    local value = bounds.object(followed.value)
    return not retry and value ~= nil and value.retry ~= true
end

local function main()
    worker.run({name = "bee.gov.activation_worker", demand = true, pass = drain})
end

return {main = main, drain = drain}
