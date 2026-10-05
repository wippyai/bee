-- MIT. Exercise the same subject attribution and policy scope as the HTTP hook adapter.
local boundary = require("boundary")
local bounds = require("bounds")
local subject_call = require("subject_call")
return {handle = function(value: unknown): {[string]: unknown}
    local input = assert(bounds.object(value))
    local binding = assert(bounds.object(input.binding))
    assert(type(binding.binding_id) == "string" and type(binding.subject) == "string" and type(binding.action_id) == "string" and type(binding.attempt_id) == "string" and type(binding.thread_id) == "string")
    local workspace_id: string? = nil
    if binding.workspace_id ~= nil then
        assert(type(binding.workspace_id) == "string")
        workspace_id = binding.workspace_id
    end
    local origin_view: {view_id: string, instance_id: string}? = nil
    if binding.origin_view ~= nil then
        local view = assert(bounds.object(binding.origin_view))
        assert(type(view.view_id) == "string" and type(view.instance_id) == "string")
        origin_view = {view_id = view.view_id, instance_id = view.instance_id}
    end
    local identity: subject_call.Binding = {binding_id = binding.binding_id, subject = binding.subject, action_id = binding.action_id, attempt_id = binding.attempt_id, thread_id = binding.thread_id, workspace_id = workspace_id, origin_view = origin_view}
    local reply, err = boundary.deliver(identity, assert(bounds.object(input.outcome)), bounds.object(input.payload))
    return {ok = reply ~= nil, value = reply, error = err}
end}
