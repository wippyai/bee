-- MIT. Applies each activation the person approved: approvals wakes this
-- worker on every decision, and each approved activation goes to its owner,
-- which consumes the approval and applies the exact intent. A refusal leaves
-- that activation for the person to see in the Library.
local funcs = require("funcs")
local bounds = require("bounds")
local logger = require("logger")
local worker = require("worker")
local service = require("service")
local approval_service = require("approval_service")

local EFFECTS = "bee.approvals.binding:activation_effects"

-- drain offers every approved, unconsumed activation to its owner; false
-- means the queue could not be read and the drain is retried.
local function drain(): boolean
    local raw, call_error = funcs.call(EFFECTS, {limit = 16})
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local effects = value and bounds.array(value.effects, 64) or nil
    if call_error or not effects then
        logger:error("Approved activations are unreadable", {cause = tostring(call_error or (reply and reply.error))})
        return false
    end
    for _, item in ipairs(effects) do
        local effect = bounds.object(item)
        local approval_id = effect and bounds.id(effect.approval_id) or nil
        if approval_id then
            local called, applied = pcall(service.apply_approved, effect)
            if not called then
                logger:error("Approved activation failed", {approval_id = approval_id, cause = tostring(applied)})
            elseif applied.ok then
                local intent = bounds.object(applied.value)
                logger:info("Approved activation applied", {approval_id = approval_id,
                    phase = intent and intent.phase, outcome = intent and intent.outcome})
            else
                logger:warn("Approved activation was not applied", {approval_id = approval_id,
                    code = applied.code, reason = applied.message})
            end
        end
    end
    return true
end

local function main()
    worker.run({name = approval_service.ACTIVATION_WORKER_NAME, wake = approval_service.TOPIC_WAKE, pass = drain})
end

return {main = main}
