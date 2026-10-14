-- MIT. Delivery method dispatch: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local claims = require("claims")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(claims.dispatch, request)
end
return {handle = handle}
