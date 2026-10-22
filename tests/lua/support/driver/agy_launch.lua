-- MIT. The universal launch of the agy driver's descriptor on Bee's default
-- placement, for its suites. The placement resolves on each decode.
local universal = require("universal")
local placement_profiles = require("placement_profiles")
local REF = "bee.drivers.agy.descriptor:cli"
local plain = universal.launch(REF)
return {
    decode = function(value: unknown): (universal.Request?, string?)
        return universal.launch(REF, assert(placement_profiles.placement(nil))).decode(value)
    end,
    specification = plain.specification,
}
