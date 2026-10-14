-- MIT. The universal driver implements this contract method.
local universal = require("universal")
return {handle = universal.locate("bee.driver.claude.descriptor:cli")}
