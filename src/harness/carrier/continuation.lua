-- MIT. Resolve native harness continuation from committed owner state.
local bounds = require("bounds")
local checkpoint = require("checkpoint")
local M = {}
type Request = {thread_id: string, action_id: string, attempt_id: string, owner_id: string, previous_attempt_id: string, session_ref: string,
    binding_ref: string, binding_digest: string, profile_id: string, profile_digest: string}
type Call = (string, unknown) -> (unknown, string?)
local function value(call: Call, target: string, request: unknown): ({[string]: unknown}?, string?)
    local raw, err = call(target, request)
    if err then return nil, target .. ": " .. err end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then return nil, target .. " refused continuation lookup" end
    local result = bounds.object(reply.value)
    if not result then return nil, target .. " returned an invalid value" end
    return result, nil
end
function M.resolve(call: Call, request: Request): (string?, string?)
    if not bounds.id(request.previous_attempt_id) or request.previous_attempt_id == request.attempt_id then return nil, "continuation needs a distinct previous attempt" end
    if not bounds.id(request.session_ref) then return nil, "continuation needs a retained session" end
    local stored, stored_error = value(call, "bee.threads.carrier:checkpoint", {thread_id = request.thread_id, attempt_id = request.previous_attempt_id})
    if not stored then return nil, stored_error end
    if stored.attempt_id ~= request.previous_attempt_id or stored.action_id ~= request.action_id then return nil, "previous attempt belongs to another action" end
    if stored.attempt_state ~= "ended" or stored.attempt_outcome ~= "succeeded" or stored.open_turn_id ~= nil then return nil, "previous attempt has no successful completed turn" end
    local point, point_error = checkpoint.decode(stored.checkpoint)
    if not point then return nil, "previous checkpoint: " .. tostring(point_error) end
    if point.binding_ref ~= request.binding_ref or point.binding_digest ~= request.binding_digest or point.profile_id ~= request.profile_id or point.profile_digest ~= request.profile_digest then
        return nil, "previous attempt used another driver or profile"
    end
    if point.retained_session_ref ~= request.session_ref then return nil, "previous attempt did not use this retained session" end
    -- Captured-output completeness stays a separate recorded fact. The
    -- native terminal result and committed receipt decide turn completion.
    local terminal = point.terminal
    local resume_ref = terminal and bounds.id(terminal.resume_ref) or nil
    if not terminal or terminal.outcome ~= "succeeded" or not resume_ref then return nil, "native harness did not record a successful resumable result" end
    local status, status_error = value(call, "bee.placement.native:status", {attempt_id = request.previous_attempt_id})
    if not status then return nil, status_error end
    local attempt = bounds.object(status.attempt)
    if not attempt or attempt.attempt_id ~= request.previous_attempt_id or attempt.action_id ~= request.action_id or attempt.owner_id ~= request.owner_id or attempt.session_ref ~= request.session_ref then
        return nil, "previous native process has another owner or session"
    end
    if attempt.execution_state ~= "exited" then return nil, "previous native process has not exited" end
    return resume_ref, nil
end
return M
