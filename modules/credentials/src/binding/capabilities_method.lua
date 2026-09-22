-- MIT. Credential broker capabilities, for any caller.
local broker = require("broker")
local function handle(): broker.Reply
    return broker.capabilities()
end
return {handle = handle}
