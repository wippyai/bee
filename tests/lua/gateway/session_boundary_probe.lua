-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local boundary = require("boundary")
type Object = {[string]: unknown}
local WORKSPACE = string.rep("a", 32)
local function probe(raw: unknown): Object
    local request = assert(bounds.object(raw))
    local session = assert(bounds.id(request.session))
    local thread = assert(bounds.id(request.thread))
    local event = assert(bounds.id(request.event))
    local attempt = request.attempt == nil and "boundary-attempt" or assert(bounds.id(request.attempt))
    local reply, err = boundary.deliver({subject = session, workspace_id = WORKSPACE, binding_id = "boundary-binding",
        action_id = "boundary-action", attempt_id = attempt, thread_id = thread},
        {event = "UserPromptSubmit", event_id = event}, {prompt = "native prompt from the terminal"}, "hook_http")
    return {reply = reply, error = err}
end
return {probe = probe}
