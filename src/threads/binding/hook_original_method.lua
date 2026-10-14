local boundary = require("boundary")
local original = require("original")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(original.read, request)
end
return {handle = handle}
