-- MIT. Applies each activation the person approved: approvals wakes this
-- worker on every decision, and each approved activation goes to its owner,
-- which consumes the approval and applies the exact intent. A refusal leaves
-- that activation for the person to see in Overlays.
local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local bounds = require("bounds")
local logger = require("logger")
local service = require("service")
local approval_service = require("approval_service")
type Channel = channel.Channel

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
            local applied = service.apply_approved(effect)
            if not applied.ok then
                logger:warn("Approved activation was not applied", {approval_id = approval_id,
                    code = applied.code, reason = applied.message})
            end
        end
    end
    return true
end

local function main()
    local lifecycle = assert(process.events())
    local wakes = assert(process.listen(approval_service.TOPIC_WAKE, {message = true}))
    local registered, register_error = process.registry.register(approval_service.ACTIVATION_WORKER_NAME)
    if not registered then error("register activation worker: " .. tostring(register_error)) end
    local retry_ms = 1000
    local retrying = not drain()
    while true do
        local cases = {lifecycle:case_receive(), wakes:case_receive()}
        if retrying then cases[#cases + 1] = time.after(tostring(retry_ms) .. "ms"):case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then return end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then return end
        else
            retrying = not drain()
            retry_ms = retrying and math.min(retry_ms * 2, 30000) or 1000
        end
    end
end

return {main = main}
