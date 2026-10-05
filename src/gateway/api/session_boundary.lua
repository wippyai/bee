-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local json = require("json")
local subject_call = require("subject_call")
local M = {}
type Object = {[string]: unknown}
function M.deliver(binding: subject_call.Binding, outcome: Object, payload: Object?, transport: string?): (Object?, string?)
    local event, event_id = outcome.event, bounds.id(outcome.event_id)
    if event ~= "UserPromptSubmit" and event ~= "Stop" and event ~= "StopFailure" and event ~= "PermissionRequest" then return {}, nil end
    if not event_id then return nil, "hook occurrence omitted its identity" end
    if binding.subject:sub(1, 3) ~= "bs:" then return {}, nil end
    local request: Object = {session = binding.subject, event = event, attempt_id = binding.attempt_id, operation_key = event_id}
    if event == "UserPromptSubmit" and payload and payload.prompt ~= nil then
        local prompt = bounds.text(payload.prompt, 65536)
        if not prompt then return nil, "native prompt exceeds its bound" end
        request.input = prompt
    end
    if event == "Stop" and payload and payload.last_assistant_message ~= nil then
        local answer = bounds.text(payload.last_assistant_message, 65536)
        if not answer then return nil, "the agent's reply exceeds its bound" end
        request.answer = answer
    end
    if event == "PermissionRequest" then
        if not payload or not transport then return nil, "permission hook omitted its transport or input" end
        request.permission = {payload = payload, transport = transport, action_id = binding.action_id, binding_id = binding.binding_id}
    end
    local reply = subject_call.call(binding, {"bee.gateway.security:session_boundary_policy"},
        "bee.threads.sessions.binding:hook_boundary", request)
    if not reply.ok then return nil, reply.error and reply.error.message or "session boundary unavailable" end
    local value = bounds.object(reply.value)
    if not value or bounds.fields(value, {"additional_context", "permission_response"}) then return nil, "invalid session boundary reply" end
    if event == "PermissionRequest" then
        if value.permission_response == nil then return {}, nil end
        local line = bounds.text(value.permission_response, 4096)
        if not line then return nil, "invalid permission hook response" end
        local decoded = bounds.object(json.decode(line))
        if not decoded then return nil, "permission hook response is not JSON" end
        return decoded, nil
    end
    if value.additional_context == nil then return {}, nil end
    local context = bounds.text(value.additional_context, 24576)
    if not context then return nil, "session boundary context exceeds its bound" end
    return {hookSpecificOutput = {hookEventName = "UserPromptSubmit", additionalContext = context}}, nil
end
return M
