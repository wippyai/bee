-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local json = require("json")
local hooks = require("hooks")
local subject_call = require("subject_call")
local hook_response = require("hook_response")
local gateway = require("gateway")
local M = {}
type Object = {[string]: unknown}
type Fault = {code: string, message: string}
local function fault(code: string, message: string): (Object?, Fault?) return nil, {code = code, message = message} end
-- answer hands one recorded hook occurrence to its session owner and returns
-- the hook's answer. A refused Bee permission answer reaches the agent as a
-- denial with its reason; any other refusal keeps the owner's error code.
local function answer(binding: subject_call.Binding, outcome: Object, payload: Object?, transport: string?): (Object?, Fault?)
    local event, event_id = outcome.event, bounds.id(outcome.event_id)
    if event ~= "SessionStart" and event ~= "UserPromptSubmit" and event ~= "PreToolUse" and event ~= "PostToolUse" and event ~= "Stop" and event ~= "StopFailure" and event ~= "PermissionRequest" then return {}, nil end
    if not event_id then return fault("INVALID", "hook occurrence omitted its identity") end
    local window = binding.subject:sub(1, 3) == "bs:"
    if not window and event ~= "PermissionRequest" then return {}, nil end
    if payload then
        local decoded, decode_error = hooks.payload(payload)
        if not decoded then return fault("INVALID", tostring(decode_error)) end
        payload = decoded
    end
    local request: Object = {session = binding.subject, binding_id = binding.binding_id, event = event, attempt_id = binding.attempt_id, operation_key = event_id, hook_payload = payload}
    if event == "UserPromptSubmit" and payload and payload.prompt ~= nil then
        local prompt = bounds.text(payload.prompt, 65536)
        if not prompt then return fault("INVALID", "native prompt exceeds its bound") end
        request.input = prompt
    end
    if event == "Stop" and payload and payload.last_assistant_message ~= nil then
        local answer = bounds.text(payload.last_assistant_message, 65536)
        if not answer then return fault("INVALID", "the agent's reply exceeds its bound") end
        request.answer = answer
    end
    if event == "PermissionRequest" then
        if not payload or not transport then return fault("INVALID", "permission hook omitted its transport or input") end
        request.permission = {payload = payload, transport = transport, action_id = binding.action_id, binding_id = binding.binding_id}
    end
    local target = "bee.threads.sessions.binding:hook_boundary"
    if not window then
        target = event == "PermissionRequest" and "bee.harness.binding:permission_hook" or "bee.harness.binding:extension_hook"
        request = {binding_id = binding.binding_id, event_id = event_id, payload = payload}
    end
    local reply = subject_call.call(binding, {"bee.gateway.security:session_boundary_policy"}, target, request)
    if not reply.ok then
        local refused = reply.error or {code = "UNAVAILABLE", message = "session boundary unavailable"}
        if event == "PermissionRequest" and refused.code == "PERMISSION_REFUSED" then
            return {hookSpecificOutput = {hookEventName = "PermissionRequest", decision = {behavior = "deny", message = refused.message}}}, nil
        end
        return fault(refused.code, refused.message)
    end
    local value = bounds.object(reply.value)
    if not value or bounds.fields(value, {"additional_context", "permission_response", "extension_response", "hook_driver"}) then return fault("INTERNAL", "invalid session boundary reply") end
    if event == "PermissionRequest" then
        if value.permission_response == nil then return {}, nil end
        local line = bounds.text(value.permission_response, 4096)
        if not line then return fault("INTERNAL", "invalid permission hook response") end
        local decoded = bounds.object(json.decode(line))
        if not decoded then return fault("INTERNAL", "permission hook response is not JSON") end
        return decoded, nil
    end
    if value.extension_response ~= nil then
        local driver = bounds.id(value.hook_driver)
        if not driver then return fault("INTERNAL", "a hook answer names no session driver") end
        local rendered, render_error = hook_response.render(tostring(event), value.extension_response, driver)
        if not rendered then return fault("INTERNAL", tostring(render_error)) end
        return rendered, nil
    end
    if value.additional_context == nil then return {}, nil end
    local context = bounds.text(value.additional_context, 24576)
    if not context then return fault("INTERNAL", "session boundary context exceeds its bound") end
    return {hookSpecificOutput = {hookEventName = "UserPromptSubmit", additionalContext = context}}, nil
end
-- deliver answers one hook. A window session takes every occurrence as it
-- is delivered, so delivery settles it in the gateway's record.
function M.deliver(binding: subject_call.Binding, outcome: Object, payload: Object?, transport: string?): (Object?, Fault?)
    local context, refused = answer(binding, outcome, payload, transport)
    local event_id = bounds.id(outcome.event_id)
    if binding.subject:sub(1, 3) == "bs:" and event_id and outcome.status == "queued" then
        local settled = gateway.hook_delivered(binding.binding_id, event_id, refused and (refused.code .. ": " .. refused.message) or nil)
        if not settled.ok then
            local fault = settled.error or {code = "STORAGE", message = "settle delivered hook"}
            return nil, {code = fault.code, message = fault.message}
        end
    end
    return context, refused
end
return M
