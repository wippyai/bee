-- MIT. Applies each activation the person approved and ends each one whose
-- request was denied, expired or withdrawn: approvals wakes this worker on
-- every decision and expiry, and each wake runs one activation pass.
local logger = require("logger")
local worker = require("worker")
local pass = require("pass")
local service = require("service")
local bounds = require("bounds")
local approval_service = require("approval_service")

-- drain runs one pass and reports each activation; false means a queue could
-- not be read and the drain is retried.
local function drain(): boolean
    local outcomes, pass_error = pass.run()
    if not outcomes then
        logger:error("Activation queues are unreadable", {cause = pass_error})
        return false
    end
    for _, item in ipairs(outcomes) do
        if item.ok then
            logger:info(item.kind == "approved" and "Approved activation applied" or "Ended activation settled",
                {approval_id = item.approval_id, phase = item.phase, outcome = item.outcome})
        else
            logger:warn(item.kind == "approved" and "Approved activation was not applied" or "Ended activation was not settled",
                {approval_id = item.approval_id, code = item.code, reason = item.message})
        end
    end
    local followed = service.follow_all()
    if not followed.ok then
        logger:error("Source following ledger is unreadable", {cause = followed.message})
        return false
    end
    local value = bounds.object(followed.value)
    return value ~= nil and value.retry ~= true
end

local function main()
    worker.run({name = "bee.gov.activation_worker", wake = approval_service.TOPIC_WAKE, pass = drain})
end

return {main = main}
