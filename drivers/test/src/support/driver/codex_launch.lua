-- MIT. The universal launch of the codex driver's descriptor, for its suites.
local universal = require("universal")
local isolations = require("isolations")
return universal.launch("bee.drivers.codex.descriptor:cli", isolations.NATIVE)
