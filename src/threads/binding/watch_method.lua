-- MIT. Delivery method watch: one read-only bounded wait that claims nothing.
local boundary = require("boundary")
local waits = require("waits")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(waits.watch, request)
end
return {handle = handle}
