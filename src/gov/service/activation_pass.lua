-- MIT. One pass of the activation worker: each approved activation goes to its
-- owner, which consumes the approval and applies the exact intent, and each
-- activation whose request was denied, expired or withdrawn settles so, which
-- lets the Library offer its version to install again.
local funcs = require("funcs")
local bounds = require("bounds")
local service = require("service")

local M = {}

local EFFECTS = "bee.approvals.binding:effect_queue"

-- One activation the pass carried: approved and applied, or ended.
type Outcome = {approval_id: string, kind: "approved" | "ended", ok: boolean,
    phase: unknown, outcome: unknown, code: unknown, message: unknown}

local function queue(phase: string): ({unknown}?, string?)
    local raw, call_error = funcs.call(EFFECTS, {destination = "gov.activation", phase = phase, limit = 16})
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local items = value and bounds.array(value.effects, 64) or nil
    if call_error or not items then return nil, tostring(call_error or (reply and reply.error)) end
    return items, nil
end

local function carry(items: {unknown}, kind: "approved" | "ended", outcomes: {Outcome})
    for _, item in ipairs(items) do
        local request = bounds.object(item)
        local approval_id = request and bounds.id(request.approval_id) or nil
        if approval_id then
            local called, result = pcall(kind == "approved" and service.apply_approved or service.close_ended, request)
            if not called then
                outcomes[#outcomes + 1] = {approval_id = approval_id, kind = kind, ok = false, phase = nil,
                    outcome = nil, code = "INTERNAL", message = tostring(result)}
            else
                local intent = bounds.object(result.value)
                outcomes[#outcomes + 1] = {approval_id = approval_id, kind = kind, ok = result.ok == true,
                    phase = intent and intent.phase, outcome = intent and intent.outcome,
                    code = result.code, message = result.message}
            end
        end
    end
end

function M.pending(): boolean
    local approved, problem = queue(EFFECTS, "effects")
    if not approved then error(problem) end
    local ended, failure = queue(CLOSURES, "closures")
    if not ended then error(failure) end
    return #approved > 0 or #ended > 0
end

-- run carries both queues once; nil with the cause when a queue is unreadable.
function M.run(): ({Outcome}?, string?)
    local outcomes: {Outcome} = {}
    local approved, approved_error = queue("ready")
    if not approved then return nil, "approved activations are unreadable: " .. tostring(approved_error) end
    carry(approved, "approved", outcomes)
    local ended, ended_error = queue("ended")
    if not ended then return nil, "ended activations are unreadable: " .. tostring(ended_error) end
    carry(ended, "ended", outcomes)
    return outcomes, nil
end

return M
