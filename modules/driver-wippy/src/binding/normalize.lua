local protocol = require("protocol")
local normalizer = require("normalizer")

return {handle = normalizer.bind(protocol.new, protocol.decode_state, protocol.normalize, protocol.finish)}
