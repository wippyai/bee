-- MIT. The universal launch of the claude driver's descriptor, for its suites.
local universal = require("universal")
local placements = require("placements")
return universal.launch("bee.drivers.claude.descriptor:cli", placements.NATIVE)
