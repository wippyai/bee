-- MIT. Delivery method page: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local subscriptions = require("subscriptions")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(subscriptions.page, request)
end
return {handle = handle}
