-- MIT. The claude driver's codec with its descriptor's JSON paths, for its suites.
local codec = require("codec")
local descriptor = require("descriptor")
local bounds = require("bounds")
type Object = {[string]: unknown}
local REF = "bee.drivers.claude.descriptor:cli"
return {
    new = codec.new,
    finish = codec.finish,
    normalize = function(state: codec.State, index: integer, envelope: Object): codec.Step
        local selected, load_error = descriptor.load(REF)
        if not selected then error(tostring(load_error)) end
        return codec.normalize(state, index, envelope, bounds.object(selected.json_paths) or {})
    end,
}
