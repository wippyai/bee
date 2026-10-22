-- MIT. The universal launch of the muse driver's descriptor, for its suites.
local universal = require("universal")
local placements = require("placements")
return universal.launch("bee.drivers.muse.descriptor:cli", placements.NATIVE)
