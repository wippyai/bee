local protocol = require("protocol")
local normalizer = require("normalizer")

return {handle = function(request: unknown) return normalizer.handle(request, {
    new = protocol.new,
    decode_state = protocol.decode_state,
    normalize = protocol.normalize,
    finish = protocol.finish,
    project = function(step: protocol.Step) return {observations = step.observations, terminal = step.terminal} end,
}) end}
