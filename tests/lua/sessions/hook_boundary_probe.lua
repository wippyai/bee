-- MIT. Exercise the same subject attribution and policy scope as the HTTP hook adapter.
local boundary = require("boundary")
local bounds = require("bounds")
local subject_call = require("subject_call")
return {handle = function(value: unknown): {[string]: unknown}
    local input = assert(bounds.object(value))
    local binding = assert(bounds.object(input.binding)) :: subject_call.Binding
    local reply, err = boundary.deliver(binding, assert(bounds.object(input.outcome)))
    return {ok = reply ~= nil, value = reply, error = err}
end}
