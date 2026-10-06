-- MIT. One pass of the activation worker, which the suites run themselves
-- while the worker service stays stopped: every approved, unconsumed
-- activation goes to its owner, which consumes the approval and applies it.
local funcs = require("funcs")
local bounds = require("bounds")
local service = require("service")

type Outcome = {approval_id: string, ok: boolean, phase: unknown, outcome: unknown, message: unknown}

local function drain(): {Outcome}
    local raw, call_error = funcs.call("bee.approvals.binding:activation_effects", {limit = 16})
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local effects = value and bounds.array(value.effects, 64) or nil
    if call_error or not effects then error("approved activations are unreadable: " .. tostring(call_error)) end
    local outcomes: {Outcome} = {}
    for _, item in ipairs(effects) do
        local effect = bounds.object(item)
        local approval_id = effect and bounds.id(effect.approval_id) or nil
        if approval_id then
            local applied = service.apply_approved(effect)
            local intent = bounds.object(applied.value)
            outcomes[#outcomes + 1] = {approval_id = approval_id, ok = applied.ok == true,
                phase = intent and intent.phase, outcome = intent and intent.outcome, message = applied.message}
        end
    end
    return outcomes
end

return {drain = drain}
