-- MIT. The universal driver evaluates host-probed facts for this descriptor.
local universal = require("universal")
return {handle = universal.locate("bee.driver.opencode.descriptor:cli")}
