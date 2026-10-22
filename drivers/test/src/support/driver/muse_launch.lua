-- MIT. The universal launch of the muse driver's descriptor, for its suites.
local universal = require("universal")
local isolations = require("isolations")
return universal.launch("bee.drivers.muse.descriptor:cli", isolations.NATIVE)
