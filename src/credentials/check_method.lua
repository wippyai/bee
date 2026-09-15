-- MIT. Credential broker method check: the caller's actor, the linked store, one operation.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.check(request)
end
return {handle = handle}
