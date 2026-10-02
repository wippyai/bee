-- MIT. Carrier method checkpoint: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local carrier = require("carrier")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(carrier.checkpoint, request, false)
end
return {handle = handle}
