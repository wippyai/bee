-- MIT. Exercise the same subject attribution and policy scope as the HTTP hook adapter.
local boundary = require("boundary")
local bounds = require("bounds")
local subject_call = require("subject_call")
return {handle = function(value: unknown): {[string]: unknown}
    local input = assert(bounds.object(value))
    local binding = assert(bounds.object(input.binding))
    assert(type(binding.binding_id) == "string" and type(binding.subject) == "string" and type(binding.action_id) == "string" and type(binding.attempt_id) == "string" and type(binding.thread_id) == "string")
    local identity: subject_call.Binding = {binding_id = binding.binding_id, subject = binding.subject, action_id = binding.action_id, attempt_id = binding.attempt_id, thread_id = binding.thread_id}
    local reply, err = boundary.deliver(identity, assert(bounds.object(input.outcome)))
    return {ok = reply ~= nil, value = reply, error = err}
end}
