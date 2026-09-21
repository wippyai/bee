local capabilities = require("capabilities")
local function handle(): capabilities.Report
    return capabilities.describe()
end
return {handle = handle}
