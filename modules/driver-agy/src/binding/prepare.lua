-- MIT. The universal driver implements this contract method.
local universal = require("universal")
return {handle = universal.prepare("bee.driver.agy.descriptor:cli")}
