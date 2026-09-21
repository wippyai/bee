-- MIT. Driver method normalize for muse: one envelope, or the end of
-- the stream, into observations and an optional terminal report. The
-- caller keeps the state between calls.
local protocol = require("protocol")
local bounds = require("bounds")
type Reply = {ok: boolean, error: string?, state: protocol.State?, observations: {{[string]: unknown}}?, terminal: unknown}
local function handle(request: unknown): Reply
    local object = bounds.object(request)
    if not object then return {ok = false, error = "request must be an object"} end
    local unknown_field = bounds.fields(object, {"state", "index", "envelope", "eof", "resumed"})
    if unknown_field then return {ok = false, error = unknown_field} end
    local index = bounds.count(object.index)
    if not index then return {ok = false, error = "index must be a nonnegative integer"} end
    if object.eof ~= nil and type(object.eof) ~= "boolean" then return {ok = false, error = "eof must be a boolean"} end
    if object.resumed ~= nil and type(object.resumed) ~= "boolean" then return {ok = false, error = "resumed must be a boolean"} end
    local state: protocol.State
    if object.state == nil then
        state = protocol.new(object.resumed == true)
    else
        local decoded, state_error = protocol.decode_state(object.state)
        if not decoded then return {ok = false, error = state_error or "state is invalid"} end
        state = decoded
    end
    local step: protocol.Step
    if object.eof == true then
        step = protocol.finish(state, index)
    else
        local envelope = bounds.object(object.envelope)
        if not envelope then return {ok = false, error = "envelope must be an object"} end
        step = protocol.normalize(state, index, envelope)
    end
    local reply: Reply = {ok = true, state = state, observations = step.observations}
    reply.terminal = step.terminal
    return reply
end
return {handle = handle}
