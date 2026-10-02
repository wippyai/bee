-- MIT. Delivery method watch: the caller's actor, the linked store, one
-- read-only operation. It claims nothing, so it is not a mutation and
-- notifies no waiter of a commit.
local boundary = require("boundary")
local waits = require("waits")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(waits.watch, request)
end
return {handle = handle}
