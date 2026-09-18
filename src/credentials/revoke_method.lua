-- MIT. Credential broker method revoke: the caller's actor, the linked store, one operation.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.revoke(request)
end
return {handle = handle}
