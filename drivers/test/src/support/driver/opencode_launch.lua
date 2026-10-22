-- MIT. The universal launch of the opencode driver's descriptor, for its suites.
local universal = require("universal")
local placements = require("placements")
return universal.launch("bee.drivers.opencode.descriptor:cli", placements.NATIVE)
