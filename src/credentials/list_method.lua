-- MIT. Credential broker method list: the caller's actor, the linked store, one operation.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.list(request)
end
return {handle = handle}
