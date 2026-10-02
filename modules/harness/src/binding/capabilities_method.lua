-- MIT. Carrier capabilities: bounds and the takeover rule, for any caller.
local machine = require("machine")
local function handle(): {[string]: unknown}
    return machine.capabilities()
end
return {handle = handle}
