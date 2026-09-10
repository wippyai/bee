-- MIT. Delivery method subscribe: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local subscriptions = require("subscriptions")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(subscriptions.subscribe, request, true)
end
return {handle = handle}
