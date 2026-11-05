-- MIT. Placement method close_stdin: the caller's actor, the linked store, one operation.
local operations = require("operations")
local function handle(request: unknown): operations.Reply
    return operations.close_stdin(request)
end
return {handle = handle}
