-- MIT. Native managed-window process entry.
--
-- The lifecycle lives in runtime.lua so component-owned process entries can
-- reuse it with a different process-local Window implementation. This entry
-- preserves the existing application identity and native implementation.
local runtime = require("runtime")
local window = require("window")

return {main = function(value: unknown)
    return runtime.main(value, window :: runtime.Window)
end}
