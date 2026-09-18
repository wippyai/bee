-- MIT. Fixed supervisor entry for authenticated node-level replica receipt.
local admission = require("admission")
local function handle(request: unknown)
    return admission.handle(request)
end
return {handle = handle}
