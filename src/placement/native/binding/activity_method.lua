-- MIT. Placement method activity: the caller's actor, the linked store, one operation.
local operations = require("operations")
local function handle(request: unknown): operations.Reply
    return operations.activity(request)
end
return {handle = handle}
