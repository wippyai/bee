-- MIT. The universal launch of the grok driver's descriptor, for its suites.
local universal = require("universal")
local isolations = require("isolations")
return universal.launch("bee.drivers.grok.descriptor:cli", isolations.NATIVE)
