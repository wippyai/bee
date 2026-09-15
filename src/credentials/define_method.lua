-- MIT. Credential broker method define: the caller's actor, the linked store, one operation.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.define(request)
end
return {handle = handle}
