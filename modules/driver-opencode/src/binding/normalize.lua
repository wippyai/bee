local protocol = require("protocol")
local normalizer = require("normalizer")

local function normalize(state: protocol.State, index: integer, envelope: {[string]: unknown}): (protocol.Step?, string?)
    return protocol.normalize(state, index, envelope), nil
end

local function finish(state: protocol.State, index: integer): (protocol.Step?, string?)
    return protocol.finish(state, index), nil
end

return {handle = function(request: unknown) return normalizer.handle(request, {
    new = protocol.new,
    decode_state = protocol.decode_state,
    normalize = normalize,
    finish = finish,
    project = function(step: protocol.Step) return {observations = step.observations, terminal = step.terminal} end,
}) end}
