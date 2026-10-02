-- MIT. Projection method recap_update: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local recap = require("recap")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(recap.update, request)
end
return {handle = handle}
