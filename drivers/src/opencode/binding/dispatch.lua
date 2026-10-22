-- MIT. The universal driver implements this contract method.
local universal = require("universal")
return {handle = universal.dispatch("bee.drivers.opencode.descriptor:cli")}
