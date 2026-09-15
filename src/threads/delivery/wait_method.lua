-- MIT. Delivery method wait: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local waits = require("waits")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(waits.wait, request, true)
end
return {handle = handle}
