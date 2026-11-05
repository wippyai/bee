-- MIT. Placement method status: the caller's actor, the linked store, one operation.
local operations = require("operations")
local function handle(request: unknown): operations.Reply
    return operations.status(request)
end
return {handle = handle}
