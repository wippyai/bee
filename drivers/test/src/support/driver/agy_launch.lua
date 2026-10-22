-- MIT. The universal launch of the agy driver's descriptor, for its suites.
local universal = require("universal")
local placements = require("placements")
return universal.launch("bee.drivers.agy.descriptor:cli", placements.NATIVE)
