-- Shared inspection for an attempt abandoned before its child starts.
local placement_decode = require("placement_decode")
local service_reply = require("service_reply")
local M = {}
M.CARRIER_REGISTRY_PREFIX = "bee.harness.carrier/"

type Outcome = "failed" | "uncertain"
type Caller = (string, unknown) -> (unknown, unknown?)
type Inspection = {outcome: Outcome, reason: string}

local function append(reason: string, detail: string): string
    return reason .. "; " .. detail
end

function M.inspect(call: Caller, status_target: string?, stop_target: string?, attempt_id: string,
    initial_outcome: Outcome, initial_reason: string): Inspection
    local outcome, reason = initial_outcome, initial_reason
    if not status_target then
        return {outcome = "uncertain", reason = append(reason, "placement binds no status operation")}
    end
    local raw, call_error = call(status_target, {attempt_id = attempt_id})
    if call_error then
        return {outcome = "uncertain", reason = append(reason, "placement status failed: " .. tostring(call_error))}
    end
    local status_reply, reply_error = service_reply.decode(raw)
    if not status_reply then
        return {outcome = "uncertain", reason = append(reason, "placement status returned an invalid reply: " .. tostring(reply_error))}
    end
    if not status_reply.ok then
        if status_reply.error.code == "NOT_FOUND" then
            return {outcome = outcome, reason = append(reason, "placement did not record an attempt")}
        end
        return {outcome = "uncertain", reason = append(reason, "placement status failed: " .. status_reply.error.message)}
    end
    local status, status_error = placement_decode.status(status_reply.value)
    if not status then
        return {outcome = "uncertain", reason = append(reason, "placement status is malformed: " .. tostring(status_error))}
    end
    local execution = status.attempt.execution_state
    if execution == "intended" then
        reason = append(reason, "placement had not started a child")
    else
        outcome = "uncertain"
        reason = append(reason, "placement had reached " .. execution)
    end
    if stop_target then
        local stop_raw, stop_call_error = call(stop_target, {attempt_id = attempt_id, mode = "cooperative"})
        if stop_call_error then
            reason = append(reason, "placement stop failed: " .. tostring(stop_call_error))
        else
            local stop_reply, stop_reply_error = service_reply.decode(stop_raw)
            if not stop_reply then
                reason = append(reason, "placement stop returned an invalid reply: " .. tostring(stop_reply_error))
            elseif not stop_reply.ok then
                reason = append(reason, "placement stop failed: " .. stop_reply.error.message)
            end
        end
    end
    return {outcome = outcome, reason = reason}
end

return M
