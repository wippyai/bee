-- MIT. Approval ingress method append: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local ingress = require("ingress")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(ingress.append, request, true)
end
return {handle = handle}
