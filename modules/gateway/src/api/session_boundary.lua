-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local subject_call = require("subject_call")
local M = {}
type Object = {[string]: unknown}
function M.deliver(binding: subject_call.Binding, outcome: Object): (Object?, string?)
    local event, event_id = outcome.event, bounds.id(outcome.event_id)
    if event ~= "UserPromptSubmit" and event ~= "Stop" and event ~= "StopFailure" then return {}, nil end
    if not event_id then return nil, "hook occurrence omitted its identity" end
    if binding.subject:sub(1, 3) ~= "bs:" then return {}, nil end
    local reply = subject_call.call(binding, {"bee.gateway.security:session_boundary_policy"},
        "bee.sessions.binding:hook_boundary", {session = binding.subject, event = event, attempt_id = binding.attempt_id, operation_key = event_id})
    if not reply.ok then return nil, reply.error and reply.error.message or "session boundary unavailable" end
    local value = bounds.object(reply.value)
    if not value or bounds.fields(value, {"additional_context"}) then return nil, "invalid session boundary reply" end
    if value.additional_context == nil then return {}, nil end
    local context = bounds.text(value.additional_context, 24576)
    if not context then return nil, "session boundary context exceeds its bound" end
    return {hookSpecificOutput = {hookEventName = "UserPromptSubmit", additionalContext = context}}, nil
end
return M
