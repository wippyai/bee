-- MIT. Credential broker method materialize: the caller's actor, the linked store, one operation.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.materialize(request)
end
return {handle = handle}
