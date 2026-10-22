-- MIT. The universal launch of the grok driver's descriptor, for its suites.
local universal = require("universal")
local placements = require("placements")
return universal.launch("bee.drivers.grok.descriptor:cli", placements.NATIVE)
