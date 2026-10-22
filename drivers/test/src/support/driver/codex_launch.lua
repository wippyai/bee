-- MIT. The universal launch of the codex driver's descriptor, for its suites.
local universal = require("universal")
local placements = require("placements")
return universal.launch("bee.drivers.codex.descriptor:cli", placements.NATIVE)
