-- MIT. Credential broker method issue_projection: the caller's actor, the linked store, one operation.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.issue_projection(request)
end
return {handle = handle}
