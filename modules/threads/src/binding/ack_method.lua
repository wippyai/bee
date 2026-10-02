-- MIT. Delivery method ack: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local claims = require("claims")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(claims.ack, request, true)
end
return {handle = handle}
