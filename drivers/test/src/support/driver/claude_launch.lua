-- MIT. The universal launch of the claude driver's descriptor, for its suites.
local universal = require("universal")
local isolations = require("isolations")
return universal.launch("bee.drivers.claude.descriptor:cli", isolations.NATIVE)
