-- MIT. The universal launch of the agy driver's descriptor, for its suites.
local universal = require("universal")
local isolations = require("isolations")
return universal.launch("bee.drivers.agy.descriptor:cli", isolations.NATIVE)
