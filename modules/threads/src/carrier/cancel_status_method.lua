-- MIT. Carrier method cancel_status: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local carrier = require("carrier")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(carrier.cancel_status, request, false)
end
return {handle = handle}
